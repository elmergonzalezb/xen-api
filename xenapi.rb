#!/usr/bin/env ruby

require 'json'
require 'nori'
require 'openssl'
require 'xmlrpc/client'

require_relative 'messages'

# XenApi Session Manager
class XenApi
  # https://stackoverflow.com/questions/11918905/ruby-which-exception-is-best-to-handle-unset-environment-variables
  XEN_SERVER_PORT = ENV['XEN_SERVER_PORT'].empty? ? 443    : ENV['XEN_SERVER_PORT'].to_i
  XEN_SERVER_USER = ENV['XEN_SERVER_USER'].empty? ? 'root' : ENV['XEN_SERVER_USER']

  # Config Client
  def initialize
    # This is where the connection is made
    # https://stelfox.net/blog/2012/02/rubys-xmlrpc-client-and-ssl/
    connection_param = {
      host: session_server_path,
      port: XEN_SERVER_PORT,
      use_ssl: true,
      path: '/'
    }
    @connect = XMLRPC::Client.new_from_hash(connection_param)
    # This is the SSL Check Bypassing Mechanism
    @connect.http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    # Save the Session Key
    @session = @connect.call('session.login_with_password', XEN_SERVER_USER, session_server_password)['Value']
  end

  # Generate Session Key
  def logout
    @connect.call('session.logout', @session)
  end

  # Get All Virtual Machines
  def all_vm
    all_records = @connect.call('VM.get_all', @session)['Value']
    # Filter Away Template
    no_template = all_records.select do |opaqueref|
      !check_vm_entity_is_template(opaqueref)
    end
    # Filter Away Control Domain
    no_template.select do |opaqueref|
      !check_vm_entity_is_dom0(opaqueref)
    end
  end

  # Get Virtual Machines Detail by OpaqueRef
  # Translate all datetime to Human-readable stuffs
  def get_vm_record(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      record = @connect.call('VM.get_record', @session, opaqueref)['Value']
      # Post processing
      # 1. Decode Time Object to Human-readable
      record['snapshot_time'] = record['snapshot_time'].to_time.to_s
      # 2. Last Boot Record is JSON, decode to Ruby Hash so that it won't clash the JSON generator
      record['last_booted_record'] = parse_last_boot_record(record['last_booted_record'])
      # 3. Parse Recommendations into Hash, using oga
      record['recommendations'] = xml_parse(record['recommendations'])
      # Output. return is redundant in Ruby World.
      record
    end
  end

  # Get Various Physical Details about the VM
  # Also need to translate all datetime to Human-readable stuffs
  def get_vm_metrics(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_metrics', @session, opaqueref)['Value']
      dat = @connect.call('VM_metrics.get_record', @session, ref)['Value']
      # convert mess stuffs to Human-readable
      dat['start_time']   = dat['last_updated'].to_time.to_s
      dat['install_time'] = dat['last_updated'].to_time.to_s
      dat['last_updated'] = dat['last_updated'].to_time.to_s
      # Output. return is redundant in Ruby World.
      dat
    end
  end

  # Get Various Runtime Detail about the VM
  # Allllllso need to translate all datetime to Human-readable stuffs
  def get_vm_guest_metrics(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_guest_metrics', @session, opaqueref)['Value']
      dat = @connect.call('VM_guest_metrics.get_record', @session, ref)['Value']
      # convert mess stuffs to Human-readable
      dat['last_updated'] = dat['last_updated'].to_time.to_s
      # Output. return is redundant in Ruby World.
      dat
    end
  end

  # Get VM Network IPs
  # http://discussions.citrix.com/topic/244784-how-to-get-ip-address-of-vm-network-adapters/
  def get_vm_guest_metrics_network(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_guest_metrics', @session, opaqueref)['Value']
      @connect.call('VM_guest_metrics.get_networks', @session, ref)['Value']
    end
  end

  # Switch On Virtual Machines
  def vm_power_on(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      callback = @connect.call('VM.start', @session, opaqueref, false, false)
      if callback['Status'] != 'Success'
        Messages.error_switch(callback['ErrorDescription'][0])
      else
        Messages.success_nodesc
      end
    end
  end

  # Switch Off Virtual Machines
  def vm_power_off(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      callback = @connect.call('VM.shutdown', @session, opaqueref)
      if callback['Status'] != 'Success'
        Messages.error_switch(callback['ErrorDescription'][0])
      else
        Messages.success_nodesc
      end
    end
  end

  # Reboot Virtual Machines
  def vm_power_reboot(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      callback = @connect.call('VM.hard_reboot', @session, opaqueref)
      if callback['Status'] != 'Success'
        Messages.error_switch(callback['ErrorDescription'][0])
      else
        Messages.success_nodesc
      end
    end
  end

  # Suspend Virtual Machines
  def vm_power_pause(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      # API Manual P116
      # void suspend (session_id s, VM ref vm)
      this_task = @connect.call('Async.VM.suspend', @session, opaqueref)
      if this_task['Status'] != 'Success'
        Messages.error_switch(this_task['ErrorDescription'][0])
      else
        task_status = task_status(this_task['Value'])
        while task_status == 'pending'
          task_status = task_status(this_task['Value'])
          sleep(5)
        end
        if task_status == 'success'
          task_destroy(this_task['Value'])
          Messages.success_nodesc
        else
          error_info = task_error(this_task['Value'])
          task_destroy(this_task['Value'])
          Messages.error_unknown(error_info[0])
        end
      end
    end
  end

  # Wake the Virtual Machines
  def vm_power_unpause(opaqueref)
    if check_vm_entity_validity(opaqueref)
      Messages.error_not_permitted
    else
      # API Manual P116-117
      # void resume (session_id s, VM ref vm, bool start_paused, bool force)
      # var this_task   String(OpaqueRef)   Reference Key of this AsyncTask
      this_task = @connect.call('Async.VM.resume', @session, opaqueref, false, false)
      if this_task['Status'] != 'Success'
        Messages.error_switch(this_task['ErrorDescription'][0])
      else
        task_status = task_status(this_task['Value'])
        while task_status == 'pending'
          task_status = task_status(this_task['Value'])
          sleep(5)
        end
        if task_status == 'success'
          task_destroy(this_task['Value'])
          Messages.success_nodesc
        else
          error_info = task_error(this_task['Value'])
          task_destroy(this_task['Value'])
          Messages.error_unknown(error_info)
        end
      end
    end
  end

  # Clone the target Virtual Machine
  # Returns the record of new vm
  # param: old_vm_opaqueref String  VM Identifier
  # param: new_vm_name      String  Name of new VM
  # APIDoc P111, Copy tens to be more guaranteed.
  # This is a long long long task so this task will not include success check.
  def vm_clone(old_vm_opaqueref, new_vm_name)
    if check_vm_entity_validity(old_vm_opaqueref) || new_vm_name.nil? || new_vm_name == ''
      Messages.error_not_permitted
    else
      # The NULL Reference is required to fulfill the requirement.
      this_task = @connect.call('Async.VM.copy', @session, old_vm_opaqueref, new_vm_name, 'OpaqueRef:NULL')
      if this_task['Status'] != 'Success'
        Messages.error_switch(this_task['ErrorDescription'][0])
      else
        task_status = task_status(this_task['Value'])
        while task_status == 'pending'
          task_status = task_status(this_task['Value'])
          sleep(5)
        end
        if task_status == 'success'
          new_vm_ref = task_result(this_task['Value'])
          task_destroy(this_task['Value'])
          Messages.success_nodesc_with_payload(new_vm_ref['value'])
        else
          error_info = task_error(this_task['Value'])
          task_destroy(this_task['Value'])
          Messages.error_unknown(error_info)
        end
      end
    end
  end

  # Erase the target Virtual Machine, along with related VDIs
  # Returns the record of new vm
  # TODO: Cleanup the EBS
  def vm_destroy(old_vm_opaqueref)
    if check_vm_entity_validity(old_vm_opaqueref)
      Messages.error_not_permitted
    else
      # The NULL Reference is required to fulfill the requirement.
      this_task = @connect.call('Async.VM.destroy', @session, old_vm_opaqueref)
      if this_task['Status'] != 'Success'
        Messages.error_switch(this_task['ErrorDescription'][0])
      else
        task_status = task_status(this_task['Value'])
        while task_status == 'pending'
          task_status = task_status(this_task['Value'])
          sleep(5)
        end
        if task_status == 'success'
          task_destroy(this_task['Value'])
          Messages.success_nodesc
        else
          error_info = task_error(this_task['Value'])
          task_destroy(this_task['Value'])
          Messages.error_unknown(error_info)
        end
      end
    end
  end

  #---
  # Collection: Task
  #---

  # All Task
  def task_all_records
    @connect.call('task.get_all_records')['Value']
  end

  # Task Record
  def task_record(task_opaqueref)
    @connect.call('task.get_record', @session, task_opaqueref)['Value']
  end

  # Task Status
  def task_status(task_opaqueref)
    @connect.call('task.get_status', @session, task_opaqueref)['Value']
  end

  # Task Result
  def task_result(task_opaqueref)
    xml_parse(@connect.call('task.get_result', @session, task_opaqueref)['Value'])
  end

  # Task Errors
  def task_error(task_opaqueref)
    @connect.call('task.get_error_info', @session, task_opaqueref)['Value']
  end

  # Destroy a task, import after working on a Async Task
  def task_destroy(task_opaqueref)
    @connect.call('task.destroy', @session, task_opaqueref)['Value']
  end

  private

  # Guard Clause for Server Address
  def session_server_path
    return ENV['XEN_SERVER_ADDR'] unless ENV['XEN_SERVER_ADDR'].nil? || ENV['XEN_SERVER_ADDR'].empty?
    raise LoadError 'Environment Variable XEN_SERVER_ADDR is required'
  end

  # Guard Clause for Server Password
  def session_server_password
    return ENV['XEN_SERVER_PASS'] unless ENV['XEN_SERVER_PASS'].nil? || ENV['XEN_SERVER_PASS'].empty?
    raise LoadError 'Environment Variable XEN_SERVER_PASS is required'
  end

  # Check the requested entity is the dom0 or not.
  def check_vm_entity_is_dom0(opaqueref)
    @connect.call('VM.get_is_control_domain', @session, opaqueref)['Value']
  end

  # Check the requested entity is an Template or not.
  def check_vm_entity_is_template(opaqueref)
    @connect.call('VM.get_is_a_template', @session, opaqueref)['Value']
  end

  # Check Existency
  def check_vm_entity_is_nonexist(opaqueref)
    result = @connect.call('VM.get_uuid', @session, opaqueref)['Status']
    result == 'Success' ? false : true
  end

  # Refactor: Aggregated Validity Check
  def check_vm_entity_validity(opaqueref)
    check_vm_entity_is_nonexist(opaqueref) || check_vm_entity_is_dom0(opaqueref) || check_vm_entity_is_template(opaqueref) || opaqueref == '' || opaqueref.nil?
  end

  # Parse the last boot record to Hash.
  # You may say why don't I just put JSON.parse.
  # The main problem is some VM that uses maybe older XS Guest Additions
  # generates ('struct') instead of pretty JSON string
  # This parser is adapted from https://gist.github.com/ascendbruce/7070951
  def parse_last_boot_record(raw_last_boot_record)
    parsed = JSON.parse(raw_last_boot_record)
    puts raw_last_boot_record
    # Also need to convert mess stuffs to Human-readable
    parsed['last_start_time'] = Time.at(parsed['last_start_time']).to_s
    parsed
  rescue JSON::ParserError
    # Ruby rescue is catch in other languages
    # Parsing struct is farrrrrrr to difficult
    Messages.error_unsupported
  end

  # XML Parser, important
  # https://github.com/savonrb/nori
  def xml_parse(raw_xml)
    xml_parser = Nori.new(parser: :rexml, convert_tags_to: ->(tag) { tag.snakecase.to_sym })
    xml_parser.parse(raw_xml)
  end
end
