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
    queue_in.subscribe(block: true) do |_, properties, body|
      Thread.new { Processor.process(body, properties.correlation_id) }
    end
  rescue Interrupt => _
    @channel.close
    @connection.close
  end

  # Message Queue Publisher
  def publish(message, corr)
    @channel.default_exchange.publish(message, routing_key: queue_out.name, correlation_id: corr)
    @channel.close
    @connection.close
  end

  private

  # Set up the ingoing queue
  def queue_in
    @channel.queue('hypervisor-net', durable: true)
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
        when 'get.vdi.all'
          xenapi.vdi_list('include')
        when 'get.vdi.iso'
          xenapi.vdi_list('only')
        when 'get.vdi.disk'
          xenapi.vdi_list('exclude')
        when 'get.vdi.my'
          xenapi.vdi_search_by_tag('userid:' + payload)
        when 'get.vdi.snapshot'
          xenapi.vdi_list_snapshot
        when 'get.vdi.tools'
          xenapi.vdi_list_tools
        when 'get.vdi.detail'
          xenapi.vdi_get_record(payload)
        when 'do.vdi.resize'
          xenapi.vdi_resize(payload['vdi_ref'], payload['vdi_new_size'])
        when 'get.vdi.tag'
          xenapi.vdi_add_tag(payload['vdi_ref'])
        when 'set.vdi.tag'
          xenapi.vdi_add_tag(payload['vdi_ref'], payload['tag'])
        when 'no.set.vm.tag'
          xenapi.vdi_rm_tag(payload['vdi_ref'], payload['tag'])
        when 'do.vdi.destroy'
          xenapi.vdi_destroy(payload)
        when 'get.vbd.all'
          xenapi.vbd_list
        when 'get.vbd.detail'
          xenapi.vbd_get_detail2(payload)
        when 'do.vbd.create'
          xenapi.vbd_create(payload['vm_ref'], payload['vdi_ref'], payload['vm_slot'])
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
