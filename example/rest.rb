#!/usr/bin/env ruby

require 'json'
require_relative '../xenapi.rb'
require_relative '../messages.rb'
require 'sinatra/base'
require 'sinatra/json'
require 'sinatra/namespace'

# Class: API
# Inherits from Sinatra::Application, the Application core.
class API < Sinatra::Base
  register Sinatra::JSON
  register Sinatra::Namespace

  xenapi = XenApi.new(ENV['XAPI_PATH'], ENV['XAPI_PORT'], ENV['XAPI_SSL'].to_s.eql?('true') ? true : false)
  xenapi.session_login(ENV['XAPI_USER'], ENV['XAPI_PASS'])

  namespace '/vm' do
    # Show the records in the database
    get '/' do
      json xenapi.vm_list_all
    end

    get '/:uuid' do |uuid|
      json xenapi.vm_get_record(uuid)
    end

    get '/:uuid/metrics' do |uuid|
      json xenapi.vm_get_guest_metrics(uuid)
    end

    get '/:uuid/ip' do |uuid|
      json xenapi.vm_get_guest_metrics_network(uuid)
    end

    get '/templates' do
      json xenapi.vm_list_all_templates
    end

    get '/templates/:uuid' do |uuid|
      json xenapi.vm_get_template_record(uuid)
    end
  end
end
