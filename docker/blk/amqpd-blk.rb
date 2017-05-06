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
    @channel.queue('hypervisor-blk-in', durable: true)
  end

  # Set up the outgoing queue
  def queue_out
    @channel.queue('out', durable: true)
  end
end

##
# Convert Size to Byte-size
class Calculator
  def self.to_byte(number, unit)
    if unit == 'G'
      number * 1024 * 1024 * 1024
    elsif unit == 'M'
      number * 1024 * 1024
    end
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
    msg = {
      seq: parsed['id'],
      taskid: parsed['uuid'],
      timestamp: Time.now.to_s,
      payload: \
        case parsed['task']
        when 'do.vdi.resize'
          xenapi.vdi_resize(payload['vdi_ref'], Calculator.to_byte(payload['vdi_size'], payload['vdi_unit']))
        when 'set.vdi.tag'
          xenapi.vdi_add_tag(payload['ref'], payload['tag'])
        when 'no.set.vm.tag'
          xenapi.vdi_rm_tag(payload['ref'], payload['tag'])
        when 'do.vdi.destroy'
          xenapi.vdi_destroy(payload)
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
begin
  rabbit.start
rescue Interrupt => _
  @channel.close
  @connection.close
end
