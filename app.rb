# frozen_string_literal: true

require 'sinatra'
require 'sinatra/reloader' if development?
require 'active_support/core_ext/object/blank'
require 'yaml'
require 'date'

def config_file_content(filename)
  File.read(File.expand_path("config/#{filename}", File.dirname(__FILE__)))
end

def development?
  Sinatra::Base.development?
end

config = YAML.safe_load(config_file_content('config.yml'))
last_serial = { date: nil, counter: 0 }

put '/hostnames' do
  return status 500 if config['auth_token'].blank?
  return status 401 if request.env['HTTP_X_AUTHORIZATION'] != config['auth_token']

  begin
    data = JSON.parse(request.body.read)
  rescue JSON::ParserError
    return status 400
  end

  return status 422 if data['prefix'].blank? || data['ipv4'].blank?

  if last_serial[:date] == Date.today
    last_serial[:counter] += 1
  else
    last_serial[:date] = Date.today
    last_serial[:counter] = 0
  end

  counter = format('%.2d', last_serial[:counter])
  serial = "#{Time.now.strftime('%Y%m%d')}#{counter}"
  prefix = data['prefix']
  ipv4 = data['ipv4']

  return status 500 if config['target_zone'].blank?
  zonefile = ERB.new(config_file_content('zonefile.zone.erb'))
  target = development? ? '/tmp' : '/usr/local/etc/nsd/zones'
  target += "/#{config['target_zone']}.zone"
  return status 500 unless development? || File.exist?(target)
  File.write(target, zonefile.result(binding))

  return 500 unless development? || system("nsd-control reload '#{config['target_zone']}'")

  status 204
end

get '/remote-address' do
  request.env['REMOTE_ADDR']
end

not_found do
  'Unknown action.'
end
