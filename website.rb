require 'fileutils'
require 'securerandom'
require 'aws'
require 'mime/types'

class Website
  def initialize(domain, &blk)
    @domain = domain
    @puts = if block_given?
              blk
            else
              proc { |s| $stdout.puts(s) }
            end
  end

  def puts(*args)
    args.each { |a| @puts.call a }
  end

  def render
    port = rand(1025..9999)
    FileUtils.rm_rf 'output'
    FileUtils.rm_rf "localhost:#{port}"

    system "bundle --deploy --retry 3 --jobs 4"
    pid = spawn("RACK_ENV=production ruby app.rb -p port")
    system "wget --mirror localhost:#{port}"
    Process.kill 'INT', pid
    Process.wait pid

    FileUtils.mv "localhost:#{port}", "output"
  end

  def compressable?(f)
    MIME::Types.of(f).first.to_s =~ /^text|javascript$|xml$|x-font-truetype$/
  end

  def gzip
    files = Dir['output/**/*'].select{ |f| File.file? f }
    files.each do |f|
      next unless compressable? f

      size = File.size f
      system "gzip --best --no-name #{f}"
      gzip_size = File.size "#{f}.gz"
      puts "Compressing: #{f} saving #{(size - gzip_size)/1024} KB"
      FileUtils.mv "#{f}.gz", f
    end
  end

  CACHE_CONTROL = 'public, max-age=300, s-maxage=86400'
  def upload
    render
    gzip
    files = Dir['output/**/*'].select{ |f| File.file? f }
    s3 = AWS::S3.new
    objects = s3.buckets[@domain].objects

    changed = []
    objects.each do |obj|
      if f = files.find {|fn| fn == "output/#{obj.key}" }
        md5 = Digest::MD5.file(f).to_s
        if not obj.etag[1..-2] == md5
          ct = MIME::Types.of(f).first.to_s
          ct = "text/html;charset=utf-8" if ct == 'text/html'
          ce = 'gzip' if compressable? f
          puts "Updating: #{f} Content-type: #{ct} Content-encoding: #{ce}"
          o = objects[f.sub(/output\//,'')]
          o.write(file: f,
                  content_type: ct,
                  content_encoding: ce,
                  cache_control: CACHE_CONTROL)
          changed << "/#{obj.key}"
        else
          puts "Not changed: #{f}"
        end
        files.delete f
      else
        puts "Deleting: #{obj.key}"
        obj.delete
        changed << "/#{obj.key}"
      end
    end

    files.each do |f|
      ct = MIME::Types.of(f).first.to_s
      ct += ";charset=utf-8" if ct == 'text/html'
      ce = 'gzip' if ct =~ /^text|javascript$|xml$/
      puts "Uploading: #{f} Content-type: #{ct} Content-encoding: #{ce}"
      o = objects[f.sub(/output\//,'')]
      o.write(file: f, content_type: ct, content_encoding: ce, cache_control: CACHE_CONTROL)
    end

    invalidate_cf(changed)
  end

  def update_headers
    s3 = AWS::S3.new
    s3.buckets[@domain].objects.each do |o|
      h = o.head
      opts = {
        content_type: h[:content_type],
        content_encoding: h[:content_encoding],
        cache_control: CACHE_CONTROL,
      }
      puts "#{o.key} #{opts}"
      o.copy_to(o.key, opts)
    end
  end

  private
  def invalidate_cf(changed)
    if changed.length > 0
      cf = AWS::CloudFront.new
      dists = cf.client.list_distributions.items
      dist = dists.find { |d| d[:aliases][:items].include? @domain }
      if dist and cf_distribution_id = dist[:id]
        resp = cf.client.create_invalidation({
          distribution_id: cf_distribution_id,
          invalidation_batch: {
            paths: {
              items: changed,
              quantity: changed.length,
            },
            caller_reference: SecureRandom.uuid,
          }
        })
        puts "Invalidating #{changed.length} changed items on CloudFront #{cf_distribution_id}"
        wait_for_invalidation(cf_distribution_id, resp[:id]) if false
      else
        puts "Couldn't find a CloudFront distribution for #{@domain}"
      end
    end
  end

  def wait_for_invalidation(cf_distribution_id, invalidation_id)
    begin
      sleep 2
      invalid = cf.client.get_invalidation(
        distribution_id: cf_distribution_id,
        id: invalidation_id
      )
      print '.'
    end while invalid[:status] == 'InProgress'
    puts 'Done!'
  end
end

