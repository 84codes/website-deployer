require 'fileutils'
require 'securerandom'
require 'aws' # https://docs.aws.amazon.com/AWSRubySDK/latest/index.html
require 'mime/types'

class Website
  def initialize(domain)
    @domain = domain
  end

  def render
    port = rand(1025..9999)
    output_dir = "output:#{port}"
    FileUtils.rm_rf output_dir
    FileUtils.rm_rf "localhost:#{port}"

    system "bundle --retry 3 --jobs 4"
    pid = spawn "RACK_ENV=production ruby app.rb -p #{port}"
    sleep 5 # wait for app to start

    files = ["index.html", "404.html"]
    files.concat(File.readlines("Extrafiles")) if File.exist? "Extrafiles"

    files.map! { |f| "http://localhost:#{port}/#{f.sub(%r{^/}, '')}" }
    File.write "Files", files.join("\n")

    system "wget --mirror --page-requisites --no-verbose --input-file Files"
    Process.kill 'INT', pid

    FileUtils.mkdir output_dir
    FileUtils.mv Dir.glob("public/*"), output_dir
    FileUtils.mv Dir.glob("localhost:#{port}/*"), output_dir, force: true
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

  CACHE_CONTROL = 'public, max-age=86400, s-maxage=86400, stale-while-revalidate=300, stale-if-error=86400'.freeze

  def upload(force_deploy: false)
    output_dir = render
    s3 = AWS::S3.new
    objects = s3.buckets[@domain].objects
    Dir.chdir output_dir do
      files = Dir['**/*'].select { |f| File.file? f }

      changed = []
      objects.each do |obj|
        if f = files.find { |fn| fn == obj.key }
          md5 = Digest::MD5.file(f).to_s
          if obj.etag[1..-2] != md5 || force_deploy
            ct = content_type f
            puts "Updating: #{f} Content-type: #{ct}"
            objects[f].write(file: f,
                             content_type: ct,
                             cache_control: CACHE_CONTROL)
            changed << "/#{obj.key}"
            changed << "/#{obj.key.chomp 'index.html'}" if obj.key =~ /index\.html$/
          else
            puts "Not changed: #{f}"
          end
          files.delete f
        else
          puts "Deleting: #{obj.key}"
          obj.delete
          changed << "/#{obj.key}"
          changed << "/#{obj.key.chomp 'index.html'}" if obj.key =~ /index\.html$/
        end
      end

      files.each do |f|
        ct = content_type f
        puts "Uploading: #{f} Content-type: #{ct}"
        objects[f].write(file: f,
                         content_type: ct,
                         cache_control: CACHE_CONTROL)
      end
      invalidate_cf(changed, force_deploy)
    end
  end

  private

  def invalidate_cf(changed, force_deploy)
    return if changed.length.zero?
    cf = AWS::CloudFront.new
    dists = cf.client.list_distributions.items
    dist = dists.find { |d| d[:aliases][:items].include? @domain }
    if dist and cf_distribution_id = dist[:id]
      cf.client.create_invalidation(
        distribution_id: cf_distribution_id,
        invalidation_batch: {
          paths: {
            items: force_deploy ? '/*' : changed,
            quantity: changed.length,
          },
          caller_reference: SecureRandom.uuid,
        }
      )
      puts "Invalidating #{changed.length} changed items on CloudFront #{cf_distribution_id}"
      # wait_for_invalidation(cf_distribution_id, resp[:id])
    else
      puts "Couldn't find a CloudFront distribution for #{@domain}"
    end
  rescue AWS::CloudFront::Errors::ServiceUnavailable => e
    puts e.inspect
    sleep 5
    retry
  rescue AWS::CloudFront::Errors::InvalidArgument => e
    puts e.inspect
  end

  def wait_for_invalidation(cf_distribution_id, invalidation_id)
    loop do
      sleep 2
      invalid = cf.client.get_invalidation(
        distribution_id: cf_distribution_id,
        id: invalidation_id
      )
      break unless invalid[:status] == 'InProgress'
      print '.'
    end
    puts 'Done!'
  end
end
