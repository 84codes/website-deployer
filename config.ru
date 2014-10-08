$stdout.sync = $stderr.sync = true
require 'bundler/setup'
require 'sinatra/base'
require 'fileutils'
require 'tmpdir'
require 'mail'
require './website'
require 'tempfile'

class MainController < Sinatra::Base
  post '/' do
    content_type 'text/plain'
    halt 401 unless params[:API_KEY] == ENV.fetch('API_KEY')
    payload = JSON.parse request[:payload], symbolize_names: true
    unless payload[:commits].any? { |c| c[:branch] == 'master' }
      halt 200, 'No master branch commit, passing'
    end
    repo_url = "#{payload[:canon_url]}#{payload[:repository][:absolute_url]}.git"
    domain = payload[:repository][:website].sub(/https?:\/\/([^\/]+).*/, '\1')

    log = capture_output do
      Dir.mktmpdir do |path|
        Dir.chdir path do
          begin
            system "git clone --depth 1 #{repo_url} ."
            Website.new(domain).upload
          rescue
            puts "[ERROR] #{$!.inspect}"
            puts $!.backtrace.join("\n  ")
          end
        end
      end
    end

    emails = payload[:commits].map { |c| c[:raw_author] }.uniq
    Mail.deliver do
      from 'system@84codes.com'
      to emails
      subject "#{domain} deploy log"
      body log
    end
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
        :address              => "email-smtp.us-east-1.amazonaws.com",
        :port                 => 587,
        :domain               => "cloudamqp.com",
        :user_name            => ENV.fetch('SES_ACCESS_KEY'),
        :password             => ENV.fetch('SES_SECRET_KEY'),
        :authentication       => 'plain',
        :enable_starttls_auto => true
      }
    end
  end
end

run MainController

