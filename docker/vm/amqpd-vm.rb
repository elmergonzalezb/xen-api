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
    @channel.queue('hypervisor-vm-in', durable: true)
  end

  # Set up the outgoing queue
  def queue_out
    @channel.queue('hypervisor-vm-out', durable: true)
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
        when 'set.vm.power_on'
          xenapi.vm_power_on(payload)
        when 'set.vm.power_off'
          xenapi.vm_power_off(payload)
        when 'set.vm.power_reboot'
          xenapi.vm_power_reboot(payload)
        when 'set.vm.power_suspend'
          xenapi.vm_power_pause(payload)
        when 'set.vm.power_resume'
          xenapi.vm_power_unpause(payload)
        when 'set.vm.name'
          xenapi.vm_set_name(payload['vm'], payload['name'])
        when 'set.vm.tag'
          xenapi.vm_add_tag(payload['vm'], payload['tag'])
        when 'no.set.vm.tag'
          xenapi.vm_rm_tag(payload['vm'], payload['tag'])
        when 'set.vm.ram'
          xenapi.vm_set_max_ram(payload['vm'], Calculator.to_byte(payload['ram_size'], payload['ram_unit']))
        when 'do.vm.clone'
          response = Array.new(2)
          response[0] = xenapi.vm_clone(payload['src_vm'], payload['new_vm_name'])
          unless response[0]['Status'] == 'Success'
            response[1] = xenapi.vm_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
          end
          response
        when 'do.vm.clone.from_template'
          cmd_prefix = \
            case payload['distro']
            when 'debianlike'
              '-- console=hvc0 ks='
            when 'rhlike'
              'console=hvc0 utf8 nogpt noipv6 ks='
            when 'sleslike'
              'console=xvc0 xencons=xvc autoyast2='
            end
          response = Array.new(3)
          response[0] = xenapi.vm_clone_from_template(\
            payload['src_vm'], \
            payload['new_vm_name'], \
            cmd_prefix + payload['ks_url'], \
            payload['repo_url'], \
            payload['distro'], \
            payload['deb_distro_release'], \
            payload['network_ref'],
            Calculator.to_byte(payload['disk_size'], payload['disk_unit'])
          )
          unless response[0]['Status'] != 'Success'
            response[1] = xenapi.vm_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
          end
          unless response[1]['Status'] != 'Success'
            response[2] = xenapi.vm_set_max_ram(response[0]['Value'], Calculator.to_byte(payload['ram_size'], payload['ram_unit']))
          end
          response
        when 'do.vm.destroy'
          xenapi.vm_destroy(payload)
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
