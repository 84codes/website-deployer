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
  post '/' do
    content_type 'text/plain'
    data = request.body.read
    digest = OpenSSL::Digest.new('sha1')
    key = ENV.fetch 'GITHUB_SECRET'
    hmac = OpenSSL::HMAC.hexdigest(digest, key, data)
    sign = request.env["HTTP_X_HUB_SIGNATURE"][5..-1]
    halt 401 unless sign == hmac
    payload = JSON.parse data, symbolize_names: true
    unless payload[:ref] == "refs/heads/master"
      halt 200, 'No master branch commit, passing'
    end
    clone_url = URI.parse payload[:repository][:clone_url]
    clone_url.userinfo = "#{ENV.fetch 'OAUTH_TOKEN'}:x-oauth-basic"
    domain = payload[:repository][:homepage].sub(%r{https?://([^/]+).*}, '\1')

    log = capture_output do
      Dir.mktmpdir do |path|
        Dir.chdir path do
          begin
            system "git clone --depth 1 #{clone_url} ."
            Website.new(domain).upload
          rescue => e
            puts "[ERROR] #{e.inspect}"
            puts e.backtrace.join("\n  ")
          end
        end
      end
    end

    emails = payload[:commits].map { |c| c[:author][:email] }.uniq
    Mail.deliver do
      from 'system@84codes.com'
      to emails
      subject "#{domain} deploy log"
      body log
    end
    200
  end

  helpers do
    def capture_output
      org_stdout = $stdout.dup
      org_stderr = $stderr.dup
      t = Tempfile.new 'out'
      $stdout.reopen t
      $stderr.reopen t
      yield
      $stdout.rewind
      $stderr.rewind
      return t.read
    ensure
      $stdout.reopen org_stdout
      $stderr.reopen org_stderr
      t.unlink
    end
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
end

run MainController
