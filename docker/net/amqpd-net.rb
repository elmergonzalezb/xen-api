#!/usr/bin/env ruby

require 'bunny'
require 'json'
require_relative './xenapi.rb'
require_relative './messages.rb'

# Class: Rabbit
# A class to manage the DNS AMQP API
class Rabbit
  # initialize by define and start connection
  def initialize
    @connection = Bunny.new(ENV['AMQP_URI'] || 'amqp://localhost')
    begin
      @connection.start
    rescue Bunny::TCPConnectionFailedForAllHosts
      sleep(5)
      retry
    end
    @channel = @connection.create_channel
  end

  # Core
  def start
    puts ' [!] Waiting for messages. To exit press CTRL+C'
    queue_in.subscribe(block: true) do |_, properties, body|
      Thread.new { Processor.process(body, properties.correlation_id) }
    end
  end

  # Message Queue Publisher
  def publish(message, corr)
    queue_out.publish(message, correlation_id: corr)
    @channel.close
    @connection.close
  end

  private

  # Set up the incoming queue
  def queue_in
    @channel.queue('hypervisor-net-in', durable: true)
  end

  # Set up the outgoing queue
  def queue_out
    @channel.queue('out', durable: true)
  end
end

# Class: Processor
# The main work logic.
class Processor
  # Process the Stuff.
  def self.process(body, msg_id)
    xenapi = XenApi.new(ENV['XAPI_PATH'], ENV['XAPI_PORT'], ENV['XAPI_SSL'].to_s.eql?('true') ? true : false)
    xenapi.session_login(ENV['XAPI_USER'], ENV['XAPI_PASS'])
    rabbit = Rabbit.new
    parsed = JSON.parse(body)
    payload = parsed['payload']
    msg = case parsed['task']
          when 'do.network.create'
            response = Array.new(2)
            response[0] = xenapi.network_create(payload['network_name'])
            unless response[0]['Status'] == 'Success'
              response[1] = xenapi.network_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
            end
            response
          when 'do.network.destroy'
            xenapi.network_destroy(payload)
          when 'set.network.tag'
            xenapi.network_add_tag(payload['ref'], payload['tag'])
          when 'no.set.network.tag'
            xenapi.network_rm_tag(payload['ref'], payload['tag'])
          when 'do.vif.create'
            xenapi.vif_create(payload['vm'], payload['net'], payload['vm_slot'])
          when 'do.vif.destroy'
            xenapi.vif_destroy(payload)
          when 'do.vif.plug'
            xenapi.vif_plug(payload)
          when 'do.vif.unplug'
            xenapi.vif_unplug(payload)
          else
            Messages.error_undefined
          end
    xenapi.session_logout
    rabbit.publish(JSON.generate(msg), msg_id)
  end
end

rabbit = Rabbit.new
begin
  rabbit.start
rescue Interrupt => _
  @channel.close
  @connection.close
end
