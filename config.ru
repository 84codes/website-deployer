$stdout.sync = $stderr.sync = true
require 'bundler/setup'
require 'sinatra/base'
require 'fileutils'
require 'tmpdir'
require 'mail'
require './website'

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
    log = []
    Dir.mktmpdir do |path|
      Dir.chdir path do
        begin
          system "git clone --depth 1 #{repo_url} ."
          Website.new(domain, proc { |s| puts s; log << s }).upload
        rescue
          log << "Exception: #{$!.inspect}"
          log.concat $!.backtrace
        end
      end
    end

    emails = payload[:commits].map { |c| c[:raw_author] }
    Mail.deliver do
      from 'system@84codes.com'
      to emails
      subject "#{domain} deploy log"
      body log.join("\n")
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

