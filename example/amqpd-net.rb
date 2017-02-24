#!/usr/bin/env ruby

require 'bunny'
require 'json'
require '../xenapi.rb'
require '../messages.rb'

# Class: Rabbit
# A class to manage the DNS AMQP API
class Rabbit
  # initialize by define and start connection
  def initialize
    @connection = Bunny.new(ENV['AMQP_URI'] || 'amqp://localhost')
    @connection.start
    @channel = @connection.create_channel
  end

  # Core
  def start
    puts ' [!] Waiting for messages. To exit press CTRL+C'
    begin
      queue_in.subscribe(block: true) do |_, properties, body|
        Thread.new { Processor.process(body, properties.correlation_id) }
      end
    rescue Interrupt => _
      @channel.close
      @connection.close
    end
  end

  # Message Queue Publisher
  def publish(message, corr)
    @channel.default_exchange.publish(message, routing_key: queue_out.name, correlation_id: corr)
    puts ' [x] SENT @ #{corr}'
    @channel.close
    @connection.close
  end

  private

  # Set up the ingoing queue
  def queue_in
    @channel.queue('hypervisor-blk', durable: true)
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
    xenapi = XenApi.new('server_path', nil, 'root', 'chnage_me')
    rabbit = Rabbit.new
    parsed = JSON.parse(body)
    payload = parsed['payload']
    puts ' [x] Task : ' + parsed['task']
    msg = {
      seq: parsed['id'],
      taskid: parsed['uuid'],
      timestamp: Time.now.to_s,
      payload: \
        case parsed['task']
        when 'get.network.all'
          xenapi.network_list
        when 'get.network.my'
          xenapi.network_search_by_tag('userid:' + payload)
        when 'get.network.detail'
          xenapi.network_get_detail(payload)
        when 'do.network.create'
          response = Array.new(2)
          response[0] = xenapi.network_create(payload['network-name'])
          unless response[0]['Status'] == 'Success'
            response[1] = xenapi.network_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
          end
          response
        when 'do.network.destroy'
          xenapi.network_destroy(payload)
        when 'get.vif.all'
          xenapi.vif_list
        when 'get.vif.info'
          xenapi.vif_get_detail(payload)
        when 'do.vif.create'
          xenapi.vif_create(payload['vm'], payload['net'], payload['vm-slot'])
        when 'do.vif.destroy'
          xenapi.vif_destroy(payload)
        when 'do.vif.plug'
          xenapi.vif_plug(payload)
        when 'do.vif.unplug'
          xenapi.vif_unplug(payload)
        else
          Messages.error_undefined
        end
    }
    xenapi.session_logout
    rabbit.publish(JSON.generate(msg), msg_id)
  end
end

rabbit = Rabbit.new
rabbit.start
