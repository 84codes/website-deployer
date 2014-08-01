$stdout.sync = $stderr.sync = true
require 'bundler/setup'
require 'sinatra/base'
require 'fileutils'
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
    name = payload[:repository][:name]
    domain = payload[:repository][:website].sub(/https?:\/\/([^\/]+).*/, '\1')
    path = "/tmp/#{name}-#{rand}"
    begin
      FileUtils.mkdir_p path
      Dir.chdir path do
        system "git clone --depth 1 #{repo_url} ."
        Website.new(domain).upload
      end
      "#{domain} deployed"
    ensure
      FileUtils.rm_rf path
    end
  end
end

run MainController

