#!/usr/bin/env ruby

require 'xmlrpc/client'
require 'bunny'
require 'json'

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
    @channel.queue('hypervisor', durable: true)
  end

  # Set up the outgoing queue
  def queue_out
    @channel.queue('out', durable: true)
  end
end

# XenApi Session Manager
class XenApi
  # Config Client
  def initialize
    @connect = XMLRPC::Client.new2('https://127.0.0.1:9443/')
    @connect.http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @session = @connect.call('session.login_with_password', ENV['XenUsername'], ENV['XenPassword'])['Value']
  end

  # Generate Session Key
  def logout
    @connect.call('session.logout', @session)
  end

  # Get All Virtual Machines
  def all_vm
    all_records = @connect.call('VM.get_all', @session)['Value']
    no_template = all_records.select do |opaqueref|
      !(@connect.call('VM.get_is_a_template', @session, opaqueref)['Value'])
    end
    no_template.select { |opaqueref| !(@connect.call('VM.get_is_is_control_domain', @session, opaqueref)['Value']) }
  end

  # Get Virtual Machines Detail by OpaqueRef
  def vm_record(opaqueref)
    restore_ref = 'OpaqueRef:' + opaqueref
    @connect.call('VM.get_record', @session, restore_ref)['Value']
  end

  # Switch On Virtual Machines
  def vm_power_on(opaqueref)
    callback = @connect.call('VM.start', @session, opaqueref, false, false)
    if callback['Status'] != 'Success'
      err_human_read = \
        case callback['ErrorDescription'][0]
        when 'OTHER_OPERATION_IN_PROGRESS'
          'Please Try Again Later. There are jobs working.'
        when 'OPERATION_NOT_ALLOWED'
          'Sorry. This action is not permitted.'
        when 'VM_BAD_POWER_STATE'
          'Sorry. This instance has been powered on.'
        else
          'Unknown Error: ' + callback['ErrorDescription'][0]
        end
      { message: 'Error', description: err_human_read }
    else
      { message: 'Success', description: 'Action Completed' }
    end
  end

  # Switch Off Virtual Machines
  def vm_power_off(opaqueref)
    callback = @connect.call('VM.shutdown', @session, opaqueref)
    if callback['Status'] != 'Success'
      err_human_read = \
        case callback['ErrorDescription'][0]
        when 'OTHER_OPERATION_IN_PROGRESS'
          'Please Try Again Later. There are jobs working.'
        when 'OPERATION_NOT_ALLOWED'
          'Sorry. This action is not permitted.'
        when 'VM_BAD_POWER_STATE'
          'Sorry. This instance is OFF.'
        else
          'Unknown Error: ' + callback['ErrorDescription'][0]
        end
      { message: 'Error', description: err_human_read }
    else
      { message: 'Success', description: 'Action Completed' }
    end
  end

  # Reboot Virtual Machines
  def vm_power_reboot(opaqueref)
    callback = @connect.call('VM.hard_reboot', @session, opaqueref)
    if callback['Status'] != 'Success'
      err_human_read = \
        case callback['ErrorDescription'][0]
        when 'OTHER_OPERATION_IN_PROGRESS'
          'Please Try Again Later. There are jobs working.'
        when 'OPERATION_NOT_ALLOWED'
          'Sorry. This action is not permitted.'
        when 'VM_BAD_POWER_STATE'
          'Sorry. This instance is OFF.'
        else
          'Unknown Error: ' + callback['ErrorDescription'][0]
        end
      { message: 'Error', description: err_human_read }
    else
      { message: 'Success', description: 'Action Completed' }
    end
  end

  # Get Various Details about the VM
  def inspect_vm_detail(opaqueref)
    # http://discussions.citrix.com/topic/244784-how-to-get-ip-address-of-vm-network-adapters/
    metric_ref = @connect.call('VM.get_guest_metrics', @session, opaqueref)['Value']
    @connect.call('VM_guest_metrics.get_record', @session, metric_ref)['Value']
  end
end

# Class: Processor
# The main work logic.
class Processor
  # Process the Stuff.
  def self.process(body, msg_id)
    xenapi = XenApi.new
    rabbit = Rabbit.new
    parsed = JSON.parse(body)
    payload = parsed['payload']
    puts ' [x] Task : ' + parsed['task']
    msg = {
      payload: nil,
      seq: parsed['id'],
      taskid: parsed['uuid']
    }
    msg['payload'] = case parsed['task']
                     when 'get.vms'
                       xenapi.all_vm
                     when 'get.vm_detail'
                       xenapi.vm_record(payload)
                     when 'get.vm_more_detail'
                       xenapi.inspect_vm_detail(payload)
                     when 'set.vm_power_on'
                       xenapi.vm_power_on(payload)
                     when 'set.vm_power_off'
                       xenapi.vm_power_off(payload)
                     when 'set.vm_power_reboot'
                       xenapi.vm_power_reboot(payload)
                     else
                       { message: 'Ouch', description: 'Job is not defined.' }
                     end
    rabbit.publish(JSON.generate(msg), msg_id)
    xenapi.logout
  end
end

rabbit = Rabbit.new
rabbit.start
