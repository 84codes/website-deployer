$stdout.sync = $stderr.sync = true
require 'bundler/setup'
require 'sinatra/base'
require 'fileutils'
require 'pp'
require './website'

class MainController < Sinatra::Base
  post '/' do
    halt 401 unless params[:API_KEY] == ENV.fetch('API_KEY')
    payload = JSON.parse request[:payload], symbolize_names: true
    repo_url = "#{payload[:canon_url]}#{payload[:repository][:absolute_url]}.git"
    path = "/tmp/#{name}-#{rand}"
    begin
      FileUtils.mkdir_p path
      Dir.chdir path do
        system "git clone --depth 1 #{repo_url} ."
        domain = File.read('Domain').strip
        Website.new(domain).upload
      end
      204
    ensure
      FileUtils.rm_rf path
    end
  end
end

run MainController

