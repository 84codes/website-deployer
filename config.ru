require 'bundle/setup'
$stdout.sync = true

require 'sinatra/base'
require 'fileutils'
require './website'

class MainController < Sinatra::Base
  post '/:name' do |name|
    puts request.body.read
    request.body.rewind
    halt 401 unless params[:key] = ENV.fetch('API_KEY')
    #data = JSON.parse request.body.read, symbolize_names: true

    domain, repo_url = SITES[name]
    repo_url = "https://bitbucket.org/84codes/#{name}-website.git"

    path = "/tmp/#{name}-#{rand}"
    begin
      FileUtils.mkdir_p pth
      Dir.chdir path do
        system "git clone --depth 1 #{repo_url} ."
        wb = Website.new(domain)
        wb.upload
      end
      204
    ensure
      FileUtils.rm_rf path
    end
  end

  SITES = {
    '84codes' => 'www.84codes.com',
    'cloudamqp' => 'www.cloudamqp.com',
  }.freeze
end

run MainController

