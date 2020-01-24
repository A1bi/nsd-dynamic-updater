# frozen_string_literal: true

require 'sinatra'
require 'sinatra/reloader' if development?
require 'active_support/core_ext/object/blank'
require 'yaml'
require 'yaml/store'
require 'date'

def config_file_path(filename)
  File.expand_path("config/#{filename}", File.dirname(__FILE__))
end

def config_file_content(filename)
  File.read(config_file_path(filename))
end

def development?
  Sinatra::Base.development?
end

def addr_for_host(hostname, type = :v6)
  settings.addresses[type][hostname] || (type == :v6 ? '::' : '127.0.0.1')
end

configure do
  config = YAML.safe_load(config_file_content('config.yml'))
  set :addresses, YAML::Store.new(config_file_path('addresses.yml'))
  set :auth_tokens, config['auth_tokens']
  set :target_zone, config['target_zone']
  set :last_serial, date: nil, counter: 0
end

put '/hostnames' do
  return status 500 unless settings.auth_tokens&.any?

  hostname = settings.auth_tokens
                     .key(request.env['HTTP_X_AUTHORIZATION'])&.to_sym
  return status 401 unless hostname.present?

  begin
    data = JSON.parse(request.body.read)
  rescue JSON::ParserError
    return status 400
  end

  return status 422 if data['prefix'].blank? || data['ipv4'].blank?

  if settings.last_serial[:date] == Date.today
    settings.last_serial[:counter] += 1
  else
    settings.last_serial[:date] = Date.today
    settings.last_serial[:counter] = 0
  end

  counter = format('%.2d', settings.last_serial[:counter])
  serial = "#{Time.now.strftime('%Y%m%d')}#{counter}"

  settings.addresses.transaction do
    settings.addresses[:v6] ||= {}
    settings.addresses[:v4] ||= {}
    settings.addresses[:v6][hostname] = data['prefix']
    settings.addresses[:v4][hostname] = data['ipv4']
    return status 500 if settings.target_zone.blank?

    zonefile = ERB.new(config_file_content('zonefile.zone.erb'))
    target = development? ? '/tmp' : '/usr/local/etc/nsd/zones'
    target += "/#{settings.target_zone}.zone"
    return status 500 unless development? || File.exist?(target)

    File.write(target, zonefile.result(binding))
  end

  return 500 unless development? ||
                    system("nsd-control reload '#{settings.target_zone}'")

  status 204
end

get '/remote-address' do
  request.env['REMOTE_ADDR']
end

not_found do
  'Unknown action.'
end
