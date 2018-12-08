# frozen_string_literal: true

require 'sinatra'
require 'sinatra/reloader' if development?
require 'active_support/core_ext/object/blank'

put '/hostnames' do
  begin
    data = JSON.parse(request.body.read)
    return status 422 if data['new_prefix'].blank?
  rescue JSON::ParserError
    return status 400
  end
  status 204
end

not_found do
  'Unknown action.'
end
