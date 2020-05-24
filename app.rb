# frozen_string_literal: true

require 'sinatra'
require 'sinatra/reloader' if development?
require 'byebug' if development?
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

def zonefile_path
  filename = "#{settings.target_zone}.zone"
  if development?
    File.expand_path(filename, File.dirname(__FILE__))
  else
    "/usr/local/etc/nsd/zones/#{filename}"
  end
end

def development?
  Sinatra::Base.development?
end

def addr_for_host(host, address_id, suffix: '')
  address = (settings.addresses[host.to_s] || {})[address_id.to_s].dup
  if address.nil?
    address = '::1'
  else
    # cut off trailing colon if suffix can't be zero-shortened
    address.delete_suffix!(':') if suffix && suffix.count(':') > 2
    address << suffix
  end
  # this will raise an exception for invalid resulting addresses
  IPAddr.new(address)
end

def address_record(name, host, address_id, suffix: '')
  address = addr_for_host(host, address_id, suffix: suffix)
  record_type = address.ipv4? ? 'A' : 'AAAA'

  "#{name} IN #{record_type} #{address}"
end

configure do
  config = YAML.safe_load(config_file_content('config.yml'))
  set :addresses, YAML::Store.new(config_file_path('addresses.yml'))
  set :clients, config['clients']
  set :target_zone, config['target_zone']
  set :last_serial, date: nil, counter: 0
end

put '/hostnames' do
  return status 500 if settings.clients.nil? || settings.target_zone.blank?

  auth_token = request.env['HTTP_X_AUTHORIZATION']
  client = settings.clients.find { |c| c['auth_token'] == auth_token }
  return status 401 if client.nil?

  begin
    data = JSON.parse(request.body.read)
  rescue JSON::ParserError
    return status 400
  end

  return status 422 unless data['addresses'].is_a? Hash

  if settings.last_serial[:date] == Date.today
    settings.last_serial[:counter] += 1
  else
    settings.last_serial[:date] = Date.today
    settings.last_serial[:counter] = 0
  end

  counter = format('%<counter>.2d', counter: settings.last_serial[:counter])
  serial = "#{Time.now.strftime('%Y%m%d')}#{counter}"

  settings.addresses.transaction do
    client_addresses = settings.addresses[client['name']] ||= {}

    data['addresses'].each do |address_id, address|
      client_addresses[address_id] = address
    end

    zonefile = ERB.new(config_file_content('zonefile.zone.erb'))
    return status 500 unless development? || File.exist?(zonefile_path)

    begin
      zonefile_content = zonefile.result(binding)
    rescue IPAddr::InvalidAddressError
      return status 422
    end

    File.write(zonefile_path, zonefile_content)
  end

  return 500 unless development? ||
                    system("nsd-control reload '#{settings.target_zone}'")

  status 204
end

get '/remote-address' do
  # request.ip alone won't work here
  # it will always priorize REMOTE_ADDR in a jailed environment
  # because REMOTE_ADDR won't be a loopback address but a global one
  request.env['HTTP_X_FORWARDED_FOR'] || request.ip
end

not_found do
  'Unknown action.'
end
