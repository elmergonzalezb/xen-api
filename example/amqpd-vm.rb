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
    @channel.queue('hypervisor-vm', durable: true)
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
        when 'get.vm.all'
          xenapi.list_all_vm
        when 'get.vm.my'
          xenapi.vm_search_by_tag('userid:' + payload)
        when 'get.vm.templates'
          xenapi.vm_list_all_templates(true)
        when 'get.vm.detail'
          xenapi.vm_get_record(payload)
        when 'get.vm.runtime_data'
          xenapi.vm_get_guest_metrics(payload)
        when 'get.vm.networks'
          xenapi.vm_get_guest_metrics_network(payload)
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
        when 'do.vm.clone'
          response = Array.new(2)
          response[0] = xenapi.vm_clone(payload['src_vm'], payload['new_vm_name'])
          unless response[0]['Status'] == 'Success'
            response[1] = xenapi.vm_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
          end
          response
        when 'do.vm.clone.from_template.debian'
          response = Array.new(2)
          response[0] = xenapi.vm_clone_from_template(\
            payload['src_vm'], \
            payload['new_vm_name'], \
            '-- console=hvc0 ks=' + payload['ks_url'], \
            payload['repo_url'], \
            'debianlike', \
            payload['deb_distro_release'], \
            payload['network_ref'],
            payload['disk_size']
          )
          unless response[0]['Status'] == 'Success'
            response[1] = xenapi.vm_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
          end
          response
        when 'do.vm.clone.from_template.rhel'
          response = Array.new(2)
          response[0] = xenapi.vm_clone_from_template(\
            payload['src_vm'], \
            payload['new_vm_name'], \
            'console=hvc0 utf8 nogpt noipv6 ks=' + payload['ks_url'], \
            payload['repo_url'], \
            'rhlike', \
            nil, \
            payload['network_ref'],
            payload['disk_size']
          )
          unless response[0]['Status'] == 'Success'
            response[1] = xenapi.vm_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
          end
          response
        when 'do.vm.clone.from_template.sle'
          response = Array.new(2)
          responsep[0] = xenapi.vm_clone_from_template(\
            payload['src_vm'], \
            payload['new_vm_name'], \
            'console=xvc0 xencons=xvc autoyast2=' + payload['ks_url'], \
            payload['repo_url'], \
            'sleslike', \
            nil, \
            payload['network_ref'],
            payload['disk_size']
          )
          unless response[0]['Status'] == 'Success'
            response[1] = xenapi.vm_add_tag(response[0]['Value'], 'userid:' + payload['userid'])
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
rabbit.start
