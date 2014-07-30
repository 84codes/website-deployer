require 'fileutils'
require 'securerandom'
require 'haml'
require 'redcarpet'
require 'aws'
require 'mime/types'

class Website
  def initialize(domain)
    @domain = domain
  end

  def clean
    FileUtils.rm_rf 'output'
    FileUtils.mkdir_p 'output'
  end

  def render
    clean
    FileUtils.cp_r 'public/.', 'output', preserve: true
    Dir.chdir 'views' do
      render_dir
    end
  end

  def gzip
    files = Dir['output/**/*'].select{ |f| File.file? f }
    files.each do |f|
      ct = MIME::Types.of(f).first.to_s
      next unless ct =~ /^text|javascript$|xml$|x-font-truetype$/

      Zlib::GzipWriter.open("#{f}.gz") do |gz|
        gz.mtime = File.mtime(f)
        gz.write IO.binread(f)
      end
      size = File.size f
      gzip_size = File.size "#{f}.gz"
      puts "Compressing: #{f} saving #{(size - gzip_size)/1024} KB"
      FileUtils.rm f
      FileUtils.mv "#{f}.gz", f
    end
  end

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
          ce = 'gzip' if ct =~ /^text|javascript$|xml$|x-font-truetype$/
          puts "Updating: #{f} Content-type: #{ct} Content-encoding: #{ce}"
          objects[f.sub(/output\//,'')].write(:file => f, :content_type => ct, content_encoding: ce)
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
      objects[f.sub(/output\//,'')].write(file: f, content_type: ct, content_encoding: ce)
    end

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
        print "Invalidating #{changed.length} changed items on CloudFront #{cf_distribution_id}"
        begin
          sleep 2
          invalid = cf.client.get_invalidation(
            distribution_id: cf_distribution_id,
            id: resp[:id]
          )
          print '.'
        end while invalid[:status] == 'InProgress'
        puts 'Done!'
      else
        puts "Couldn't find a CloudFront distribution for #{@domain}"
      end
    end
  end


  private
  HAML_OPTIONS = { format: :html5, ugly: true }.freeze
  def render_view(f, layouts)
    path = Dir.pwd.sub(/.*\/views/, '')
    name = File.basename f, '.haml'
    name = File.join(path, name)[1..-1]
    haml_view = File.read(f)
    view = Haml::Engine.new(haml_view, HAML_OPTIONS)
    ctx = HamlViewContext.new(HAML_OPTIONS)
    html = view.to_html(ctx, { name: name })
    layouts.reverse.each do |layout|
      html = layout.to_html(ctx, { name: name }) { html }
    end

    outf = File.join Dir.pwd.sub('views', 'output'), f.sub('haml', 'html')
    File.open(outf, 'w+') {|o| o.write html}
    File.utime(File.atime(outf), File.mtime(f), outf)
  end

  def render_dir(layouts = [])
    if File.exist? 'layout.haml'
      haml_layout = File.read('layout.haml')
      layout = Haml::Engine.new(haml_layout, HAML_OPTIONS)
      layouts << layout
    end
    FileUtils.mkdir_p Dir.pwd.sub('/views', '/output')
    Dir.foreach '.' do |f|
      next if f == '.' || f == '..'
      Dir.chdir f do
        render_dir layouts.dup
      end if File.directory? f
    end
    Dir.glob('*.haml') do |f|
      next if f == 'layout.haml'
      render_view(f, layouts)
    end
  end

  class HamlViewContext
    def initialize(opts)
      @opts = opts
      rnder = Redcarpet::Render::HTML.new(prettify: true)
      @markdown = Redcarpet::Markdown.new(rnder, {
        :autolink => true,
        :space_after_headers => true,
        :no_intra_emphasis => true,
        :fenced_code_blocks => true,
        :space_after_headers => true
      })
    end

    def haml(view_sym, opts)
      haml_view = File.read("#{Dir.pwd}/#{view_sym}.haml")
      engine = Haml::Engine.new(haml_view, @opts.merge(opts))
      engine.to_html(self.class.new(@opts), opts[:locals])
    end

    def markdown(view_sym)
      view = File.read("views/#{view_sym}.md")
      html = @markdown.render(view)
      html.gsub(/(\<code class=")/, '\1prettyprint ')
    end
  end
end

