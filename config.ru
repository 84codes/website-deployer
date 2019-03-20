$stdout.sync = $stderr.sync = true
require 'bundler/setup'
require 'sinatra/base'
require 'fileutils'
require 'tmpdir'
require 'mail'
require './website'
require 'tempfile'
require 'openssl'
require 'uri'
require 'json'

class MainController < Sinatra::Base
  enable :logging, :dump_errors
  @deploy_queue = Queue.new

  def self.start_deploy_loop
    Thread.new do
      loop do
        config = MainController.deploy_queue.pop
        log = MainController.capture_output do
          Dir.mktmpdir do |path|
            Dir.chdir path do
              system "git clone --depth 1 #{config[:clone_url]} ."
              Website.new(config[:domain]).upload
            rescue => e
              puts "[ERROR] #{e.inspect}"
              puts e.backtrace.join("\n  ")
            end
          end
        end
        print log

        emails = config[:payload][:commits].map { |c| c[:author][:email] }.uniq
        Mail.deliver do
          from 'system@84codes.com'
          to emails
          subject "#{config[:domain]} deploy log"
          body log
          charset = "UTF-8" # rubocop:disable Lint/UselessAssignment
        end
      end
    end
  end

  post '/' do
    content_type 'text/plain'
    data = request.body.read
    digest = OpenSSL::Digest.new('sha1')
    key = ENV.fetch 'GITHUB_SECRET'
    hmac = OpenSSL::HMAC.hexdigest(digest, key, data)
    sign = request.env["HTTP_X_HUB_SIGNATURE"][5..-1]
    halt 401 unless sign == hmac
    payload = JSON.parse data, symbolize_names: true
    halt 200, 'No master branch commit, passing' unless payload[:ref] == "refs/heads/master"
    clone_url = URI.parse payload[:repository][:clone_url]
    clone_url.userinfo = "#{ENV.fetch 'OAUTH_TOKEN'}:x-oauth-basic"
    domain = payload[:repository][:homepage].sub(%r{https?://([^/]+).*}, '\1')
    @deploy_queue.push domain: domain, clone_url: clone_url, payload: payload
    200
  end

  configure do
    Mail.defaults do
      delivery_method :smtp, {
        address: "email-smtp.us-east-1.amazonaws.com",
        port: 465,
        domain: "cloudamqp.com",
        user_name: ENV.fetch('SES_ACCESS_KEY'),
        password: ENV.fetch('SES_SECRET_KEY'),
        tls: true
      }
    end
  end

  private_class_method :capture_output

  def self.capture_output
    org_stdout = $stdout.dup
    org_stderr = $stderr.dup
    t = Tempfile.new 'out'
    $stdout.reopen t
    $stderr.reopen t
    yield
    $stdout.rewind
    $stderr.rewind
    t.read
  ensure
    $stdout.reopen org_stdout
    $stderr.reopen org_stderr
    t.unlink
  end
end

MainController.start_deploy_loop
run MainController
