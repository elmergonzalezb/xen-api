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
  begin
    xenapi.session_login(ENV['XAPI_USER'], ENV['XAPI_PASS'])
  rescue Interrupt => _
    xenapi.session_logout
  end

  get '/' do
    status 200
  end

  namespace '/vm' do
    # Show the records in the database
    get '/' do
      json xenapi.vm_list_all
    end

    get '/byuser/:userid' do |userid|
      json xenapi.vm_search_by_tag('userid:' + userid)
    end

    get '/bytag/:tag' do |tag|
      json xenapi.vm_search_by_tag(tag)
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

  namespace '/net' do
    get '/' do
      json xenapi.network_list
    end

    get '/byuser/:userid' do |userid|
      json xenapi.network_search_by_tag('userid:' + userid)
    end

    get '/bytag/:tag' do |tag|
      json xenapi.network_search_by_tag(tag)
    end

    get '/:uuid' do |uuid|
      json xenapi.network_get_detail(uuid)
    end
  end

  namespace '/block' do
    namespace '/vdi' do
      get '/' do
        json xenapi.vdi_list('include')
      end

      get '/iso' do
        json xenapi.vdi_list('only')
      end

      get '/disk' do
        json xenapi.vdi_list('exclude')
      end

      get '/byuser/:userid' do |userid|
        json xenapi.vdi_search_by_tag('userid:' + userid)
      end

      get '/bytag/:tag' do |tag|
        json xenapi.vdi_search_by_tag(tag)
      end

      get '/:uuid' do |uuid|
        json xenapi.vdi_get_record(uuid)
      end
    end

    namespace '/vbd' do
      get '/' do
        json xenapi.vbd_list
      end

      get '/:uuid' do |uuid|
        json xenapi.vbd_get_detail2(uuid)
      end
    end
  end
end

API.run!
