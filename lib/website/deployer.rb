# frozen_string_literal: true

require_relative "deployer/version"
require 'fileutils'
require 'securerandom'
require 'socket'
require 'aws-sdk-s3' # https://docs.aws.amazon.com/sdk-for-ruby/v3/api/index.html
require 'aws-sdk-cloudfront'
require 'mime/types'

module Website
  class Deployer
    REDIRECTS_FILE = "redirects.json"

    def render
      host = ENV.fetch("LOCALHOST", "localhost")
      port = random_free_port(host)
      output_dir = "output:#{port}"
      FileUtils.rm_rf output_dir
      FileUtils.rm_rf "#{host}:#{port}"

      pid = spawn "RACK_ENV=production ruby app.rb -p #{port}"
      Process.detach(pid)
      sleep 5 # wait for app to start

      files = ["index.html", "404.html"]
      files.concat(File.readlines("Extrafiles")) if File.exist? "Extrafiles"

      files.map! { |f| "http://#{host}:#{port}/#{f.sub(%r{^/}, '')}" }
      File.write "Files", files.join("\n")

      system "wget --mirror --page-requisites --no-verbose -e robots=off --input-file Files --no-http-keep-alive"
      Process.kill 'INT', pid

      FileUtils.mkdir output_dir
      FileUtils.mv Dir.glob("public/*"), output_dir
      FileUtils.mv Dir.glob("#{host}:#{port}/*"), output_dir, force: true

      Dir['**/*'].select { |f| f.include? "?" }.each { |f| FileUtils.rm f }
      output_dir
    rescue Errno::ENOENT => e
      puts e.message
      puts Dir.entries(".")
      raise
    end

    def content_type(f)
      case f.split('.').last
      when 'js'
        'application/javascript'
      else
        ct = MIME::Types.of(f).first.to_s
        ct += ';charset=utf-8' if ct == 'text/html'
        ct
      end
    end

    CACHE_CONTROL = "public, max-age=86400, s-maxage=86400, stale-while-revalidate=300,"\
      " stale-if-error=86400".freeze

    def upload(domain, force_deploy: false)
      output_dir = render
      s3 = Aws::S3::Resource.new
      bucket = s3.bucket(domain)
      objects = bucket.objects
      redirects = File.exist?(REDIRECTS_FILE) ? JSON.parse(File.read(REDIRECTS_FILE)) : {}
      puts "Found #{redirects.size} redirects"

      Dir.chdir output_dir do
        files = Dir['**/*'].select { |f| File.file? f }
        unless files.any? { |f| f =~ /index\.html$/ }
          puts "[DEBUG] no index found, files=#{files}"
          raise "Render failed!"
        end
        changed = []
        objects.each do |obj|
          encoded_key = "/#{encode_rfc1783(obj.key)}"
          if f = files.find { |fn| fn == obj.key }
            md5 = Digest::MD5.file(f).to_s
            if obj.etag[1..-2] != md5 || force_deploy
              ct = content_type f
              puts "Updating: #{f} Content-type: #{ct}"
              File.open(f) do |io|
                bucket.put_object(key: f,
                                  body: io,
                                  content_type: ct,
                                  cache_control: CACHE_CONTROL)
              end
              changed << encoded_key
              changed << encoded_key.chomp("index.html") if obj.key.end_with? "index.html"
            else
              puts "Not changed: #{f}"
            end
            files.delete f
          elsif target = redirects.delete(obj.key)
            if obj.object.website_redirect_location != target || force_deploy
              puts "Updating: redirect #{obj.key} -> #{target}"
              obj.put(website_redirect_location: target,
                      content_type: 'text/html;charset=utf-8',
                      cache_control: CACHE_CONTROL)
              changed << encoded_key
            end
          else
            puts "Deleting: #{obj.key}"
            obj.delete
            changed << encoded_key
            changed << encoded_key.chomp("index.html") if obj.key.end_with? "index.html"
          end
        end

        files.each do |f|
          ct = content_type f
          puts "Uploading: #{f} Content-type: #{ct}"
          File.open(f) do |io|
            bucket.put_object(key: f,
                              body: io,
                              content_type: ct,
                              cache_control: CACHE_CONTROL)
          end
        end

        redirects.each do |source, target|
          puts "Redirecting #{source} -> #{target}"
          bucket.put_object(key: source,
                            website_redirect_location: target,
                            content_type: 'text/html;charset=utf-8',
                            cache_control: CACHE_CONTROL)
        end
        invalidate_cf(domain, changed, force_deploy)
      end
    end

    private

    def encode_rfc1783(str)
      str.split('/').map { |s| CGI.escape(s) }.join('/')
    end

    def invalidate_cf(domain, changed, force_deploy)
      return if changed.length.zero?
      cf = Aws::CloudFront::Resource.new
      dists = cf.client.list_distributions.distribution_list.items
      dist = dists.find { |d| d[:aliases][:items].include? domain }
      if dist && cf_distribution_id = dist[:id]
        cf.client.create_invalidation(
          distribution_id: cf_distribution_id,
          invalidation_batch: {
            paths: {
              items: force_deploy ? ['/*'] : changed,
              quantity: force_deploy ? 1 : changed.length,
            },
            caller_reference: SecureRandom.uuid,
          }
        )
        puts "Invalidating #{changed.length} changed items on CloudFront #{cf_distribution_id}"
        wait_for_invalidation(cf_distribution_id, resp[:id])
      else
        puts "Couldn't find a CloudFront distribution for #{domain}"
      end
    end

    def wait_for_invalidation(cf_distribution_id, invalidation_id)
      loop do
        sleep 2
        resp = cf.client.get_invalidation(
          distribution_id: cf_distribution_id,
          id: invalidation_id
        )
        break unless resp.invalidation[:status] == 'InProgress'
        print '.'
      end
      puts 'Done!'
    end

    private

    def random_free_port(host)
      server = TCPServer.new(host, 0)
      begin
        server.addr[1]
      ensure
        server.close
      end
    end
  end
end
