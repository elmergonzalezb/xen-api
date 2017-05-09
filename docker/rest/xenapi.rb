#!/usr/bin/env ruby

require 'json'
require 'nori'
require 'openssl'
require 'xmlrpc/client'
require_relative './messages.rb'

##
# Overriding with Monkey-Patching the CONSTANT
# https://stackoverflow.com/questions/1263702/how-to-do-a-wiredump-of-xmlrpcclient-in-ruby
module XMLRPC
  ##
  # This module store config in a module...
  module Config
    ##
    # Disable SignedInt Check
    ENABLE_BIGINT = true
  end
end

##
# XenApi Session Manager
class XenApi
  ##
  # Initalize the API by login to XenServer.
  #
  # +server_path+:: Server Address
  # +server_port+:: Server API Port, useful while oeprate over SSH
  # +username+   :: Username, usually _root_
  # +password+   :: Password, the password!
  def initialize(server_path, server_port = 443, use_ssl = true)
    # This is where the connection is made
    # https://stelfox.net/blog/2012/02/rubys-xmlrpc-client-and-ssl/
    @connection_param = {
      host: server_path,
      port: server_port,
      use_ssl: use_ssl,
      path: '/'
    }
    @connect = XMLRPC::Client.new_from_hash(@connection_param)
    # This is the SSL Check Bypassing Mechanism
    @connect.http.verify_mode = OpenSSL::SSL::VERIFY_NONE unless use_ssl == false
  end

  def session_login(username, password)
    callback = @connect.call('session.login_with_password', username, password)
    if callback['Status'] == 'Error' && callback['ErrorDescription'][0] == 'HOST_IS_SLAVE'
      @connection_param[host] = callback['ErrorDescription'][1]
      @connect = XMLRPC::Client.new_from_hash(@connection_param)
      @connect.http.verify_mode = OpenSSL::SSL::VERIFY_NONE unless use_ssl == false
    else
      @session = callback['Value']
    end
  end

  ##
  # Logout
  #
  def session_logout
    @connect.call('session.logout', @session)
  end

  ##
  # logout
  #
  # Alias to session_logout
  def logout
    session_logout
  end

  ##
  # Get All Virtual Machines
  # Using list instead to circumvent RuboCop
  def vm_list_all
    all_records = @connect.call('VM.get_all', @session)
    # Filter Away Control Domain
    all_records['Value'].reject! do |vm_opaqueref|
      check_vm_entity_is_dom0(vm_opaqueref)
    end
    # Filter Away Template
    all_records['Value'].reject! do |vm_opaqueref|
      check_vm_entity_is_template(vm_opaqueref)
    end
    all_records['Value'].map! do |ref|
      vm_get_uuid(ref)['Value']
    end
    all_records
  end

  ##
  # Get all Templates
  def vm_list_all_templates
    all_records = @connect.call('VM.get_all', @session)
    # Filter Away non-template (VM Instances + dom0)
    all_records['Value'].select! do |tpl_opaqueref|
      check_vm_entity_is_template(tpl_opaqueref)
    end
    all_records['Value'].select! do |tpl_opaqueref|
      check_vm_entity_is_paravirtual(tpl_opaqueref)
    end
    all_records['Value'].map! do |ref|
      vm_get_uuid(ref)['Value']
    end
    all_records
  end

  ##
  # Get Virtual Machines Detail by OpaqueRef
  #
  # +vm_uuid+:: VM Reference
  def vm_get_record(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      record = @connect.call('VM.get_record', @session, vm_get_ref(vm_uuid)['Value'])
      # Post processing
      # 1. Decode Time Object to Human-readable
      if record.key?('Value')
        begin
          record['Value']['snapshot_time'] = record['snapshot_time'].to_time.to_s
        rescue NoMethodError
          record['Value']['snapshot_time'] = nil
        end
        record['Value']['VIFs'].map! do |vif_ref|
          vif_get_uuid(vif_ref)['Value']
        end
        record['Value']['VBDs'].map! do |vbd_ref|
          vbd_get_uuid(vbd_ref)['Value']
        end
        # 2. Last Boot Record is JSON, decode to Ruby Hash so that it won't clash
        #    the JSON generator
        record['Value']['last_booted_record'] = parse_last_boot_record(record['Value']['last_booted_record'])
      end
      # Output. return is redundant in Ruby World.
      record
    end
  end

  ##
  # Get Virtual Machines Detail by OpaqueRef
  #
  # +vm_uuid+:: VM Reference
  def vm_get_template_record(vm_uuid)
    if check_vm_template_validity(vm_uuid)
      Messages.error_not_permitted
    else
      record = @connect.call('VM.get_record', @session, vm_get_ref(vm_uuid)['Value'])
      if record.key?('Value')
        begin
          record['Value']['snapshot_time'] = record['Value']['snapshot_time'].to_time.to_s
        rescue NoMethodError
          record['Value']['snapshot_time'] = nil
        end
      end
      # Output. return is redundant in Ruby World.
      record
    end
  end

  ##
  # Get Various Physical Details about the VM
  #
  # +vm_uuid+:: VM Reference
  def vm_get_metrics(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_metrics', @session, vm_get_ref(vm_uuid)['Value'])['Value']
      dat = @connect.call('VM_metrics.get_record', @session, ref)
      # convert mess stuffs to Human-readable
      if dat.key?('Value')
        begin
          dat['Value']['start_time']   = dat['Value']['last_updated'].to_time.to_s
          dat['Value']['install_time'] = dat['Value']['last_updated'].to_time.to_s
          dat['Value']['last_updated'] = dat['Value']['last_updated'].to_time.to_s
        rescue NoMethodError
          dat['Value']['start_time']   = nil
          dat['Value']['install_time'] = nil
          dat['Value']['last_updated'] = nil
        end
      end
      # Output. return is redundant in Ruby World.
      dat
    end
  end

  ##
  # Get Various Runtime Detail about the VM
  #
  # +vm_uuid+:: VM Reference
  def vm_get_guest_metrics(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_guest_metrics', @session, vm_get_ref(vm_uuid)['Value'])['Value']
      dat = @connect.call('VM_guest_metrics.get_record', @session, ref)
      # convert mess stuffs to Human-readable
      if dat.key?('Value')
        begin
          dat['Value']['last_updated'] = dat['last_updated'].to_time.to_s
        rescue NoMethodError
          dat['Value']['last_updated'] = nil
        end
      end
      # Output. return is redundant in Ruby World.
      dat
    end
  end

  # Get VM Network IPs
  # http://discussions.citrix.com/topic/244784-how-to-get-ip-address-of-vm-network-adapters/
  #
  # +vm_uuid+:: VM Reference
  def vm_get_guest_metrics_network(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_guest_metrics', @session, vm_get_ref(vm_uuid)['Value'])['Value']
      @connect.call('VM_guest_metrics.get_networks', @session, ref)
    end
  end

  ##
  # Get Block Devices of the specified VM
  #
  # +vm_uuid+:: VM Reference
  # +uuid_mode+:: Use UUID Mode?
  def vm_get_vbds(vm_uuid, uuid_mode)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      vbds = @connect.call('VM.get_VBDs', @session, vm_get_ref(vm_uuid)['Value'])
    end
    if uuid_mode == true && vbds.key?('Value') && vbds['Value'].empty? == false
      vbds['Value'].map! do |ref|
        vbd_get_uuid(ref)['Value']
      end
    end
    vbds
  end

  ##
  # Get Virtual Network Interfaces (VIFs) of the specified VM
  #
  # +vm_uuid+:: VM Reference
  # +uuid_mode+:: Use UUID Mode?
  def vm_get_vifs(vm_uuid, uuid_mode)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      vifs = @connect.call('VM.get_VIFs', @session, vm_get_ref(vm_uuid)['Value'])
    end
    if uuid_mode == true && vifs.key?('Value') && vifs['Value'].empty? == false
      vifs['Value'].map! do |ref|
        vif_get_uuid(ref)['Value']
      end
    end
    vifs
  end

  ##
  # Power ON the specified Virtual Machine
  #
  # +vm_uuid+:: VM Reference
  def vm_power_on(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      task_token = @connect.call('Async.VM.start', @session, vm_get_ref(vm_uuid)['Value'], false, false)
      async_task_manager(task_token, false)
    end
  end

  ##
  # Power OFF the specified Virtual Machine
  #
  # +vm_uuid+:: VM Reference
  def vm_power_off(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      task_token = @connect.call('Async.VM.shutdown', @session, vm_get_ref(vm_uuid)['Value'])
      async_task_manager(task_token, false)
    end
  end

  ##
  # Reboot the specified Virtual Machines
  #
  # +vm_uuid+:: VM Reference
  def vm_power_reboot(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      task_token = @connect.call('Async.VM.hard_reboot', @session, vm_get_ref(vm_uuid)['Value'])
      async_task_manager(task_token, false)
    end
  end

  ##
  # Suspend the specified Virtual Machine
  #
  # +vm_uuid+:: VM Reference
  def vm_power_pause(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      # API Manual P116
      # void suspend (session_id s, VM ref vm)
      task_token = @connect.call('Async.VM.suspend', @session, vm_get_ref(vm_uuid)['Value'])
      async_task_manager(task_token, false)
    end
  end

  ##
  # Wake up the specified Virtual Machine
  #
  # +vm_uuid+:: VM Reference
  def vm_power_unpause(vm_uuid)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      # API Manual P116-117
      # void resume (session_id s, VM ref vm, bool start_paused, bool force)
      task_token = @connect.call('Async.VM.resume', @session, vm_get_ref(vm_uuid)['Value'], false, false)
      async_task_manager(task_token, false)
    end
  end

  ##
  # Clone the target Virtual Machine
  # Returns the reference point of new vm
  # APIDoc P111, Copy tends to be more guaranteed.
  #
  # +old_vm_uuid+:: Source VM UUID
  # +new_vm_name+     :: Name of the new VM
  # Returns:
  # the record of new vm
  def vm_clone(old_vm_uuid, new_vm_name)
    if check_vm_entity_validity(old_vm_uuid) || new_vm_name.nil? || new_vm_name == ''
      Messages.error_not_permitted
    else
      # The NULL Reference is required to fulfill the requirement.
      task_token = @connect.call('Async.VM.copy', @session, vm_get_ref(old_vm_uuid)['Value'], new_vm_name, 'OpaqueRef:NULL')
      result = async_task_manager(task_token, true)
      if result.key?('Status') && result['Status'] == 'Error'
        result
      else
        Messages.success_nodesc_with_payload(vm_get_uuid(result['value'])['Value'])
      end
    end
  end

  ##
  # Clone from PV Template
  #
  # +vm_tpl_uuid+:: Source Template UUID
  # +new_vm_name+          :: Name of the new VM
  # +pv_boot_param+        :: Boot Command Line
  # +repo_url+             :: URL of the Distro Repo
  # +distro+               :: Distro Family, acceptable values are _debian_ and _rhel_
  # +distro_release+       :: Release Name of the specified Debian/Ubuntu Release. example: _jessie_(Debian 8), _trusty_(Ubuntu 14.04)
  # Returns: The record of new vm
  def vm_clone_from_template(vm_tpl_uuid, new_vm_name, pv_boot_param, repo_url, distro, distro_release, network_uuid, dsk_size)
    if check_vm_template_validity(vm_tpl_uuid) || new_vm_name.nil? || new_vm_name == '' || repo_url.start_with?('https://')
      Messages.error_not_permitted
    else
      vm_tpl_opaqueref = vm_get_ref(vm_tpl_uuid)['Value']
      # Step0.1: Copy from template.
      # The NULL Reference is required to fulfill the params requirement.
      default_sr = sr_get_default['Value']
      task_token = @connect.call('Async.VM.copy', @session, vm_tpl_opaqueref, new_vm_name, default_sr['REF'])
      # Step0.2: get new vm reference point
      result = async_task_manager(task_token, true)['value']
      vmuuid = vm_get_uuid(result)['Value']
      disk = '<provision><disk device=\'0\' size=\'' + dsk_size.to_s + '\' sr=\'' + default_sr['UUID'] + '\' bootable=\'true\' type=\'system\'/></provision>'
      vm_set_other_config(vmuuid, 'disks', disk)
      # Step 1 : Set boot paramaters, For configuring the kickstart definition
      @connect.call('VM.provision', @session, result)
      @connect.call('VM.set_PV_args', @session, result, pv_boot_param)
      # Step 2 : Set repository URL, important for install. Always skip step if previous step has error
      #     2.1: Handling Debian-based
      if distro == 'debianlike' || distro == 'rhlike' || distro == 'sleslike'
        # Set New Value
        s = vm_set_other_config(vmuuid, 'install-repository', repo_url)
        unless s['Status'] != 'Success'
          s = vm_set_other_config(vmuuid, 'debian-release', distro_release) if distro == 'debianlike'
        end
      # Other distro is HVM so we ignore it.
      else
        Messages.error_unsupported
      end
      if s['Status'] == 'Error'
        Messages.error_unknown(s)
      else
        s = vif_create(vmuuid, network_uuid, 0)
        if s['Status'] == 'Error'
          Messages.error_unknown(s)
        else
          # callback the new vm OpaqueRef
          Messages.success_nodesc_with_payload(vm_get_uuid(result)['Value'])
        end
      end
    end
  end

  ##
  # Erase the target Virtual Machine, along with related VDIs
  #
  # +old_vm_uuid+:: VM UUID
  def vm_destroy(old_vm_uuid)
    if check_vm_entity_validity(old_vm_uuid)
      Messages.error_not_permitted
    else
      old_vm_opaqueref = vm_get_ref(old_vm_uuid)['Value']
      # Get /dev/xvda VDI Reference Code First.
      vbd_sets = vm_get_vbds(old_vm_uuid, false)['Value']
      xvda_id = ''
      vbd_sets.each do |vbd_opaqueref|
        record = vbd_get_detail2(vbd_opaqueref)['Value']
        next if record['type'] != 'Disk' || record['device'] != 'xvda'
        xvda_id = record['VDI']
      end
      # Delete VM
      task_token = @connect.call('Async.VM.destroy', @session, old_vm_opaqueref)
      result = async_task_manager(task_token, false)
      if result['Status'] == 'Success'
        # Delete VM OK => Cleanup residue: /dev/xvda VDI
        vdi_destroy2(xvda_id)
      else
        # Prompt Error on Deleting VM
        result
      end
    end
  end

  ##
  # Add 'other config', useful for official PV Instance template
  #
  # +vm_uuid+:: VM UUID
  # +key+         :: Config Key
  # +value+       :: Config Value
  def vm_add_other_config(vm_uuid, key, value)
    vm_opaqueref = vm_get_ref(vm_uuid)
    vm_opaqueref.key?('Value') ? @connect.call('VM.add_to_other_config', @session, vm_opaqueref['Value'], key, value) : vm_opaqueref
  end

  ##
  # Unset 'other config', useful for official PV Instance template
  #
  # +vm_uuid+:: VM UUID
  # +key+         :: Config Key
  def vm_rm_other_config(vm_uuid, key)
    vm_opaqueref = vm_get_ref(vm_uuid)
    vm_opaqueref.key?('Value') ? @connect.call('VM.remove_from_other_config', @session, vm_opaqueref['Value'], key) : vm_opaqueref
  end

  ##
  # Get other_config field.
  #
  # +vm_uuid+:: VM UUID
  def vm_get_other_config(vm_uuid)
    vm_opaqueref = vm_get_ref(vm_uuid)
    vm_opaqueref.key?('Value') ? @connect.call('VM.get_other_config', @session, vm_opaqueref['Value']) : vm_opaqueref
  end

  ##
  # Set 'other config', useful for official PV Instance template
  #
  # +vm_uuid+:: VM UUID
  # +key+         :: Config Key
  # +value+       :: Config Value
  def vm_set_other_config(vm_uuid, key, value)
    s = vm_rm_other_config(vm_uuid, key)
    s.key?('Value') ? vm_add_other_config(vm_uuid, key, value) : s
  end

  ##
  # Add a tag to the specified VM
  #
  # +vm_uuid+:: VM UUID
  # +tag+         :: Tag
  def vm_add_tag(vm_uuid, tag)
    @connect.call('VM.add_tags', @session, vm_get_ref(vm_uuid)['Value'], tag)
  end

  ##
  # Unset VM tags
  #
  # +vm_uuid+:: VM UUID
  # +tag+         :: Tag
  def vm_rm_tag(vm_uuid, tag)
    @connect.call('VM.remove_tags', @session, vm_get_ref(vm_uuid)['Value'], tag)
  end

  ##
  # Get VM tags
  #
  # +vm_uuid+:: VM UUID
  # +tag+         :: Tag
  # Returns: Tags
  def vm_get_tags(vm_uuid)
    @connect.call('VM.get_tags', @session, vm_get_ref(vm_uuid)['Value'])
  end

  ##
  # search VM by tag
  #
  # +tag+         :: Tag
  # Returns Matched VM
  def vm_search_by_tag(tag)
    all_vm = vm_list_all
    all_vm['Value'].select do |vm_uuid|
      vm_get_tags(vm_uuid)['Value'].include?(tag)
    end
  end

  ##
  # search Template by tag
  #
  # +tag+         :: Tag
  # Returns Matched VM
  def vm_search_templates_by_tag(tag)
    all_vm = vm_list_all_templates
    all_vm['Value'].select do |vm_uuid|
      vm_get_tags(vm_uuid)['Value'].include?(tag)
    end
  end

  ##
  # Set VM Name
  #
  # +vm_uuid+:: VM OpaqueRef
  # +vm_name+:: VM Name
  def vm_set_name(vm_uuid, vm_name)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      @connect.call('VM.set_name_label', @session, vm_get_ref(vm_uuid)['Value'], vm_name)
    end
  end

  ##
  # Set VM Memory Size
  # +vm_uuid+:: VM OpaqueRef
  # +max_size+:: Memory Capacity
  def vm_set_max_ram(vm_uuid, max_size)
    if check_vm_entity_validity(vm_uuid)
      Messages.error_not_permitted
    else
      vm_opaqueref = vm_get_ref(vm_uuid)['Value']
      begin
        @connect.call('VM.set_memory_static_max', @session, vm_opaqueref, max_size.to_i)
        @connect.call('VM.set_memory_dynamic_max', @session, vm_opaqueref, max_size.to_i)
      rescue RuntimeError
        Messages.error_unsupported
      end
    end
  end

  ##
  # Get VM uuid
  def vm_get_uuid(vm_opaqueref)
    @connect.call('VM.get_uuid', @session, vm_opaqueref)
  end

  ##
  # Get VDI OpaqueRef
  def vm_get_ref(vm_uuid)
    @connect.call('VM.get_by_uuid', @session, vm_uuid)
  end

  #---
  # Collection: Task
  #---

  ##
  # All Task
  #
  def task_list_all_records
    @connect.call('task.get_all_records', @session)
  end

  ##
  # Get Task Record
  #
  # +task_opaqueref+:: Task Reference
  def task_get_record(task_opaqueref)
    @connect.call('task.get_record', @session, task_opaqueref)
  end

  ##
  # Task Status
  #
  # +task_opaqueref+:: Task Reference
  def task_get_status(task_opaqueref)
    @connect.call('task.get_status', @session, task_opaqueref)
  end

  ##
  # Task Result
  #
  # +task_opaqueref+:: Task Reference
  def task_get_result(task_opaqueref)
    @connect.call('task.get_result', @session, task_opaqueref)
  end

  ##
  # Task Errors
  #
  # +task_opaqueref+:: Task Reference
  def task_get_error(task_opaqueref)
    @connect.call('task.get_error_info', @session, task_opaqueref)
  end

  ##
  # Destroy a task, important after working on a Async Task
  #
  # +task_opaqueref+:: Task Reference
  def task_destroy(task_opaqueref)
    @connect.call('task.destroy', @session, task_opaqueref)
  end

  ##
  # Cancel a task, important after Crashes
  #
  # +task_opaqueref+:: Task Reference
  def task_cancel(task_opaqueref)
    @connect.call('task.cancel', @session, task_opaqueref)
  end

  #---
  # Collection: VDI
  #---

  ##
  # Get a list of all VDI
  # +iso_cd+:: Ignore ISO file? possible values are inclue, exclude, only
  def vdi_list(iso_cd)
    all_records = @connect.call('VDI.get_all', @session)
    # Filter Away Snapshots
    all_records['Value'].reject! do |vdi_opaqueref|
      check_vdi_is_a_snapshot(vdi_opaqueref)
    end
    # Filter Away XS-Tools
    all_records['Value'].reject! do |vdi_opaqueref|
      check_vdi_is_xs_iso(vdi_opaqueref)
    end
    all_records['Value'].select! do |vdi_opaqueref|
      !check_vdi_is_iso(vdi_opaqueref) if iso_cd == 'exclude'
      check_vdi_is_iso(vdi_opaqueref) if iso_cd == 'only'
      true if iso_cd == 'include'
    end
    all_records['Value'].map! do |ref|
      vdi_get_uuid(ref)['Value']
    end
    all_records
  end

  ##
  # Get a list of all Snapshot VDI
  def vdi_list_snapshot
    all_records = @connect.call('VDI.get_all', @session)
    # Filter Away Snapshots
    all_records['Value'].select! do |vdi_opaqueref|
      check_vdi_is_a_snapshot(vdi_opaqueref)
    end
    all_records['Value'].map! do |ref|
      vdi_get_uuid(ref)['Value']
    end
    all_records
  end

  ##
  # Get XS-TOOLS VDI
  def vdi_list_tools
    all_records = @connect.call('VDI.get_all', @session)
    # Filter Away all butXS-Tools
    all_records['Value'].select! do |vdi_opaqueref|
      check_vdi_is_xs_iso(vdi_opaqueref)
    end
    all_records['Value'].map! do |ref|
      vdi_get_uuid(ref)['Value']
    end
    all_records
  end

  ##
  # Get detail of the specified VDI
  #
  # +vdi_uuid+:: VDI Reference
  def vdi_get_record(vdi_uuid)
    if check_vdi_entity_validity(vdi_uuid)
      Messages.error_not_permitted
    else
      record = @connect.call('VDI.get_record', @session, vdi_get_ref(vdi_uuid)['Value'])
      begin
        record['Value']['snapshot_time'] = record['Value']['snapshot_time'].to_time.to_s
      rescue NoMethodError
        true
      end
      record['Value']['VBDs'].map! do |vbd_ref|
        vbd_get_uuid(vbd_ref)['Value']
      end
      record
    end
  end

  ##
  # Resize the specified VDI
  #
  # +vdi_uuid+:: VDI Reference
  # +new_vdi_size+:: New Size of the VDI
  def vdi_resize(vdi_uuid, new_vdi_size)
    if check_vdi_entity_validity(vdi_uuid)
      Messages.error_not_permitted
    else
      begin
        @connect.call('VDI.resize_online', @session, vdi_get_ref(vdi_uuid)['Value'], new_vdi_size)
      rescue RuntimeError
        Messages.error_unsupported
      end
    end
  end

  ##
  # Destroy the specified VDI, by UUID
  #
  # +vdi_uuid+:: VDI Reference
  def vdi_destroy(vdi_uuid)
    if check_vdi_entity_validity(vdi_uuid)
      Messages.error_not_permitted
    else
      vdi_task_token = @connect.call('Async.VDI.destroy', @session, vdi_get_ref(vdi_uuid)['Value'])
      async_task_manager(vdi_task_token, false)
    end
  end

  ##
  # Destroy the specified VDI, by REF
  #
  # +vdi_opaqueref+:: VDI Reference
  def vdi_destroy2(vdi_opaqueref)
    vdi_task_token = @connect.call('Async.VDI.destroy', @session, vdi_opaqueref)
    async_task_manager(vdi_task_token, false)
  end

  ##
  # Add a tag to the specified VDI
  #
  # +vdi_uuid+:: VDI UUID
  # +tag+          :: Tag
  def vdi_add_tag(vdi_uuid, tag)
    if check_vdi_entity_validity(vdi_uuid)
      Messages.error_not_permitted
    else
      @connect.call('VDI.add_tags', @session, vdi_get_ref(vdi_uuid)['Value'], tag)
    end
  end

  ##
  # Unset VDI tags
  #
  # +vdi_uuid+:: VDI UUID
  # +tag+          :: Tag
  def vdi_rm_tag(vdi_uuid, tag)
    if check_vdi_entity_validity(vdi_uuid)
      Messages.error_not_permitted
    else
      @connect.call('VDI.remove_tags', @session, vdi_get_ref(vdi_uuid)['Value'], tag)
    end
  end

  ##
  # get VDI tags
  #
  # +vdi_uuid+:: VDI UUID
  # +tag+          :: Tag
  # Returns:
  # Tags
  def vdi_get_tags(vdi_uuid)
    if check_vdi_entity_validity(vdi_uuid)
      Messages.error_not_permitted
    else
      @connect.call('VDI.get_tags', @session, vdi_get_ref(vdi_uuid)['Value'])
    end
  end

  ##
  # Search VDI by tag
  # +tag+         :: Tag
  # Returns Matched VM
  def vdi_search_by_tag(tag)
    all_vdi = vdi_list('include')
    all_vdi['Value'].select! do |vdi_uuid|
      vdi_get_tags(vdi_uuid)['Value'].include?(tag)
    end
    all_vdi['Value'].map! do |ref|
      vdi_get_uuid(ref)['Value']
    end
    all_vdi
  end

  ##
  # Get VDI uuid
  def vdi_get_uuid(vbd_opaqueref)
    @connect.call('VDI.get_uuid', @session, vbd_opaqueref)
  end

  ##
  # Get VDI OpaqueRef
  def vdi_get_ref(vbd_uuid)
    @connect.call('VDI.get_by_uuid', @session, vbd_uuid)
  end

  #---
  # Collection: VBD (Virtual Block Devices)
  #---

  ##
  # Get all VBD on the system
  def vbd_list
    result = @connect.call('VBD.get_all', @session)
    result['Value'].map! do |ref|
      vbd_get_uuid(ref)['Value']
    end
    result
  end

  ##
  # Get detail of the specified VBD by UUID
  def vbd_get_detail(vbd_uuid)
    vbd_opaqueref = vbd_get_ref(vbd_uuid)
    if vbd_opaqueref.key?('Value')
      record = @connect.call('VBD.get_record', @session, vbd_opaqueref['Value'])
      record['Value']['VM'] = vm_get_uuid(record['Value']['VM'])['Value']
      record['Value']['VDI'] = vdi_get_uuid(record['Value']['VDI'])['Value']
      record
    else
      vbd_opaqueref
    end
  end

  ##
  # Get detail of the specified VBD by OpaqueRef
  def vbd_get_detail2(vbd_opaqueref)
    @connect.call('VBD.get_record', @session, vbd_opaqueref)
  end

  ##
  # Create a Virtual Block Device (Plugged Instantly)
  #
  # +vm_opaqueref+:: VM Reference
  # +vdi_opaqueref+:: VDI Reference
  # +device_slot+:: VBD Device place
  def vbd_create(vm_uuid, vdi_uuid, device_slot)
    if check_vm_entity_validity(vm_uuid) || check_vdi_entity_validity(vdi_uuid)
      Messages.error_not_permitted
    else
      vbd_object = {
        VM: vm_get_ref(vm_uuid)['Value'],
        VDI: vdi_get_ref(vdi_uuid)['Value'],
        userdevice: device_slot,
        bootable: false,
        mode: 'RW',
        type: 'Disk',
        empty: false,
        qos_algorithm_type: '',
        qos_algorithm_params: {}
      }
      result = @connect.call('VBD.create', @session, vbd_object)
      result['Value'] = vbd_get_uuid(result['Value'])['Value']
      result
    end
  end

  ##
  # Get VBD uuid
  def vbd_get_uuid(vbd_opaqueref)
    @connect.call('VBD.get_uuid', @session, vbd_opaqueref)
  end

  ##
  # Get VBD OpaqueRef
  def vbd_get_ref(vbd_uuid)
    @connect.call('VBD.get_by_uuid', @session, vbd_uuid)
  end

  #---
  # Collection: VIF (Virtual Network Interface)
  #---

  ##
  # List all VIF
  def vif_list
    result = @connect.call('VIF.get_all', @session)
    result['Value'].map! do |ref|
      vif_get_uuid(ref)['Value']
    end
    result
  end

  ##
  # Get details of the specified VIF
  # +vif_uuid+:: OpaqueRef of the VIF
  def vif_get_detail(vif_uuid)
    vif_opaqueref = vif_get_ref(vif_uuid)
    if vif_opaqueref.key?('Value')
      record = @connect.call('VIF.get_record', @session, vif_opaqueref['Value'])
      record['Value']['VM'] = vm_get_uuid(record['Value']['VM'])['Value']
      record['Value']['network'] = network_get_uuid(record['Value']['network'])['Value']
      record
    else
      vif_opaqueref
    end
  end

  ##
  # Create a VIF
  # +vm_uuid+:: OpaqueRef of target VM
  # +net_uuid+:: Network to be plugged
  # +slot+:: Where the VIF is 'inserted'
  def vif_create(vm_uuid, net_uuid, slot)
    net_opaqueref = network_get_ref(net_uuid)
    if check_vm_entity_validity(vm_uuid) || net_opaqueref['Status'] != 'Success'
      Messages.error_not_permitted
    else
      vif_object = {
        device: slot.to_s,
        network: net_opaqueref['Value'],
        VM: vm_get_ref(vm_uuid)['Value'],
        MAC: '',
        MTU: '1500',
        other_config: {},
        qos_algorithm_type: '',
        qos_algorithm_params: {}
      }
      result = @connect.call('VIF.create', @session, vif_object)
      result.key?('Value') ? result['Value'] = vif_get_uuid(result['Value'])['Value'] : nil
      result
    end
  end

  ##
  # Destroy the specified VIF
  # +vif_uuid+:: OpaqueRef of the VIF
  def vif_destroy(vif_uuid)
    vif_opaqueref = vif_get_ref(vif_uuid)
    vif_opaqueref.key?('Value') ? @connect.call('VIF.destroy', @session, vif_opaqueref['Value']) : vif_opaqueref
  end

  ##
  # Plug the VIF
  # +vif_uuid+:: OpaqueRef of the VIF
  def vif_plug(vif_uuid)
    vif_opaqueref = vif_get_ref(vif_uuid)
    vif_opaqueref.key?('Value') ? @connect.call('VIF.plug', @session, vif_opaqueref['Value']) : vif_opaqueref
  end

  ##
  # UnPlug the VIF
  # +vif_uuid+:: OpaqueRef of the VIF
  def vif_unplug(vif_uuid)
    vif_opaqueref = vif_get_ref(vif_uuid)
    vif_opaqueref.key?('Value') ? @connect.call('VIF.unplug', @session, vif_opaqueref['Value']) : vif_opaqueref
  end

  ##
  # Get VIF uuid
  def vif_get_uuid(vif_opaqueref)
    @connect.call('VIF.get_uuid', @session, vif_opaqueref)
  end

  ##
  # Get VIF OpaqueRef
  def vif_get_ref(vif_uuid)
    @connect.call('VIF.get_by_uuid', @session, vif_uuid)
  end

  #---
  # NET
  #---

  ##
  # List all network
  def network_list
    result = @connect.call('network.get_all', @session)
    result['Value'].map! do |ref|
      network_get_uuid(ref)['Value']
    end
    result
  end

  ##
  # Get details of the network
  def network_get_detail(network_uuid)
    network_opaqueref = network_get_ref(network_uuid)
    if network_opaqueref.key?('Value')
      record = @connect.call('network.get_record', @session, network_opaqueref['Value'])
      record['Value']['VIFs'].map! do |vif_ref|
        vif_get_uuid(vif_ref)['Value']
      end
      record
    else
      network_opaqueref
    end
  end

  ##
  # Create a Internal Network
  # +name+:: Name of the Network
  def network_create(name)
    vbd_object = {
      name_label: name,
      MTU: 1500,
      other_config: {}
    }
    result = @connect.call('network.create', @session, vbd_object)
    result['Value'] = network_get_uuid(result['Value'])['Value']
    result
  end

  ##
  # Destroy a Internal Network
  # +network_uuid+:: OpaqueRef of the Network
  def network_destroy(network_uuid)
    network_opaqueref = network_get_ref(network_uuid)
    network_opaqueref.key?('Value') ? @connect.call('network.destroy', @session, network_opaqueref['Value']) : network_opaqueref
  end

  ##
  # Tag a network
  # +network_uuid+:: OpaqueRef of the Network
  # +tag+:: the name tag
  def network_add_tag(network_uuid, tag)
    network_opaqueref = network_get_ref(network_uuid)
    network_opaqueref.key?('Value') ? @connect.call('network.add_tags', @session, network_opaqueref['Value'], tag) : network_opaqueref
  end

  ##
  # UNTag a network
  # +network_uuid+:: OpaqueRef of the Network
  # +tag+:: the name tag
  def network_rm_tag(network_uuid, tag)
    network_opaqueref = network_get_ref(network_uuid)
    network_opaqueref.key?('Value') ? @connect.call('network.remove_tags', @session, network_opaqueref['Value'], tag) : network_opaqueref
  end

  ##
  # Get Tags of network
  # +network_uuid+:: uuid of the Network
  def network_get_tags(network_uuid)
    network_opaqueref = network_get_ref(network_uuid)
    network_opaqueref.key?('Value') ? @connect.call('network.get_tags', @session, network_opaqueref['Value']) : network_opaqueref
  end

  ##
  # Search network by Tag
  # +tag+:: the name tag
  def network_search_by_tag(tag)
    networks = network_list
    networks['Value'].select! do |network_uuid|
      network_get_tags(network_uuid)['Value'].include?(tag)
    end
    networks
  end

  ##
  # Get Network uuid
  def network_get_uuid(network_opaqueref)
    @connect.call('network.get_uuid', @session, network_opaqueref)
  end

  ##
  # Get Network OpaqueRef
  def network_get_ref(network_uuid)
    @connect.call('network.get_by_uuid', @session, network_uuid)
  end

  #---
  # Collection: SR
  #---

  ##
  # List all SRs in the system
  # +iso_sr+:: include SRs for ISO file? 'include' // 'exclude' // 'only'
  # +uuid_mode+:: results in UUID? true / false
  def sr_list(iso_sr, uuid_mode)
    all_sr = @connect.call('SR.get_all', @session)
    all_sr['Value'].select! do |opaqueref|
      check_sr_is_vdisr_by_ref(opaqueref) if iso_sr == 'exclude'
      check_sr_is_iso(opaqueref) if iso_sr == 'only'
      true if iso_sr == 'include'
    end
    if uuid_mode == true
      all_sr['Value'].map! do |ref|
        sr_get_uuid(ref)['Value']
      end
    end
    all_sr
  end

  ##
  # Get SR Record
  # +sr_uuid+:: UUID of SR
  def sr_get_record(sr_uuid)
    sr_opaqueref = sr_get_ref(sr_uuid)
    sr_opaqueref.key?('Value') ? @connect.call('SR.get_record', @session, sr_opaqueref['Value']) : sr_opaqueref
  end

  ##
  # Get SR Connection by uuid
  def sr_get_type(sr_uuid)
    sr_opaqueref = sr_get_ref(sr_uuid)
    sr_opaqueref.key?('Value') ? @connect.call('SR.get_type', @session, sr_opaqueref['Value']) : sr_opaqueref
  end

  ##
  # Get SR Connection type by ref
  def sr_get_type2(sr_opaqueref)
    @connect.call('SR.get_type', @session, sr_opaqueref)
  end

  ##
  # Add a tag to the specified VDI
  #
  # +sr_uuid+:: SR UUID
  # +tag+    :: Tag
  def sr_add_tag(sr_uuid, tag)
    sr_opaqueref = sr_get_ref(sr_uuid)
    sr_opaqueref.key?('Value') ? @connect.call('SR.add_tags', @session, sr_opaqueref['Value'], tag) : sr_opaqueref
  end

  ##
  # Unset SR tags
  #
  # +sr_uuid+:: SR UUID
  # +tag+    :: Tag
  def sr_rm_tag(sr_uuid, tag)
    sr_opaqueref = sr_get_ref(sr_uuid)
    sr_opaqueref.key?('Value') ? @connect.call('SR.remove_tags', @session, sr_opaqueref['Value'], tag) : sr_opaqueref
  end

  ##
  # Find Default SR
  def sr_get_default
    default_pool = @connect.call('pool.get_all', @session)
    default_sr = @connect.call('pool.get_default_SR', @session, default_pool['Value'][0]) if default_pool['Status'] == 'Success'
    res_hash = { 'UUID' => sr_get_uuid(default_sr['Value'])['Value'], 'REF' => default_sr['Value'] }
    Messages.success_nodesc_with_payload(res_hash)
  end

  ##
  # get SR tags
  #
  # +sr_uuid+:: SR UUID
  # +tag+    :: Tag
  # Returns: Tags
  def sr_get_tags(sr_uuid)
    sr_opaqueref = sr_get_ref(sr_uuid)
    sr_opaqueref.key?('Value') ? @connect.call('SR.get_tags', @session, vdi_get_ref(vdi_uuid)['Value']) : sr_opaqueref
  end

  ##
  # Search SR by tag
  # +tag+         :: Tag
  # Returns Matched VM
  def sr_search_by_tag(tag)
    all_sr = sr_list('include', true)
    all_sr['Value'].select! do |sr_uuid|
      sr_get_tags(sr_uuid)['Value'].include?(tag)
    end
    all_sr
  end

  ##
  # Get Network uuid
  def sr_get_uuid(sr_opaqueref)
    @connect.call('SR.get_uuid', @session, sr_opaqueref)
  end

  ##
  # Get Network OpaqueRef
  def sr_get_ref(sr_uuid)
    @connect.call('SR.get_by_uuid', @session, sr_uuid)
  end

  #---
  # Private Scope is intended for wrapping non-official and refactored functions
  #---

  private

  #---
  # Pluggable FIlters
  #---

  ##
  # Filter: Check the requested VM entity is the dom0 or not.
  def check_vm_entity_is_dom0(vm_opaqueref)
    @connect.call('VM.get_is_control_domain', @session, vm_opaqueref)['Value']
  end

  ##
  # Filter: Check the requested VM entity is an Template or not.
  def check_vm_entity_is_template(vm_opaqueref)
    @connect.call('VM.get_is_a_template', @session, vm_opaqueref)['Value']
  end

  ##
  # Filter: Check VM Existency
  def check_vm_entity_is_nonexist(vm_opaqueref)
    result = @connect.call('VM.get_uuid', @session, vm_opaqueref)['Status']
    result == 'Success' ? false : true
  end

  ##
  # Filter: Check VM IS PV
  def check_vm_entity_is_paravirtual(vm_opaqueref)
    result = @connect.call('VM.get_PV_bootloader', @session, vm_opaqueref)['Value']
    # PV Templates always have pygrub in PV_bootloader field
    # https://wiki.xenproject.org/wiki/XCP_PV_templates_start
    # pygrub will be used after install finished, eliloader is used on templates
    result == 'eliloader' ? true : false
  end

  ##
  # Filter: Ignore XS-Tools ISO
  def check_vdi_is_xs_iso(vdi_opaqueref)
    @connect.call('VDI.get_is_tools_iso', @session, vdi_opaqueref)['Value']
  end

  ##
  # Filter: Ignore ISO and Hypervisor host CD drive
  # Only HDD Image can clone. resize is OK but it will not show running disk.
  def check_vdi_is_iso(vdi_opaqueref)
    result = @connect.call('VDI.get_allowed_operations', @session, vdi_opaqueref)['Value']
    read_only = @connect.call('VDI.get_read_only', @session, vdi_opaqueref)['Value']
    result.include?('clone') && read_only == false ? false : true
  end

  ##
  # Filter: Ignore Snapshots
  def check_vdi_is_a_snapshot(vdi_opaqueref)
    @connect.call('VDI.get_is_a_snapshot', @session, vdi_opaqueref)['Value']
  end

  ##
  # Check if a SR is ISO
  def check_sr_is_iso(sr_opaqueref)
    type = sr_get_type2(sr_opaqueref)['Value']
    type != 'iso' ? true : false
  end

  ##
  # Check if a SR is udes
  def check_sr_is_udev(sr_opaqueref)
    type = sr_get_type2(sr_opaqueref)['Value']
    type != 'udev' ? true : false
  end

  #---
  # Aggregated Filters
  #---

  ##
  # Refactor: Aggregated Validity Check
  def check_vm_entity_validity(vm_uuid)
    if vm_uuid == '' || vm_uuid.nil?
      true
    else
      vm_opaqueref = vm_get_ref(vm_uuid)
      vm_opaqueref['Status'] == 'Success' ? check_vm_entity_is_dom0(vm_opaqueref['Value']) || check_vm_entity_is_template(vm_opaqueref['Value']) : true
    end
  end

  ##
  # Refactor: Check Template Validity
  def check_vm_template_validity(vm_tpl_uuid)
    if vm_tpl_uuid == '' || vm_tpl_uuid.nil?
      true
    else
      vm_tpl_opaqueref = vm_get_ref(vm_tpl_uuid)
      vm_tpl_opaqueref['Status'] == 'Success' ? !check_vm_entity_is_template(vm_tpl_opaqueref['Value']) || !check_vm_entity_is_paravirtual(vm_tpl_opaqueref['Value']) : true
    end
  end

  ##
  # Refactor: Aggregated VDI Validity Check
  def check_vdi_entity_validity(vdi_uuid)
    if vdi_uuid == '' || vdi_uuid.nil?
      true
    else
      vdi_opaqueref = vdi_get_ref(vdi_uuid)
      vdi_opaqueref['Status'] == 'Success' ? check_vdi_is_a_snapshot(vdi_opaqueref['Value']) || check_vdi_is_xs_iso(vdi_opaqueref['Value']) : true
    end
  end

  ##
  # Filter away non-VM SR
  def check_sr_is_vdisr_by_ref(sr_ref)
    if sr_ref.nil? || sr_ref == ''
      false
    else
      !(check_sr_is_iso(sr_ref) && check_sr_is_udev(sr_ref))
    end
  end

  ##
  # Filter away non-VM SR
  def check_sr_is_vdisr_by_uuid(sr_uuid)
    if sr_uuid.nil? || sr_uuid == ''
      false
    else
      sr_ref = sr_get_ref(sr_uuid)
      sr_ref.key?('Value') ? !(check_sr_is_iso(sr_ref['Value']) && check_sr_is_udev(sr_ref['Value'])) : false
    end
  end

  #---
  # Tools
  #---

  ##
  # Refactor: AsyncTask Task Manager
  # It would poll the server continuously for task status
  def async_task_manager(task_opaqueref, has_payload)
    if task_opaqueref['Status'] != 'Success'
      Messages.error_switch(task_opaqueref['ErrorDescription'][0][0])
    else
      task_status = task_get_status(task_opaqueref['Value'])['Value']
      while task_status == 'pending'
        task_status = task_get_status(task_opaqueref['Value'])['Value']
        sleep(5)
      end
      if task_status == 'success' && has_payload == false
        task_destroy(task_opaqueref['Value'])
        Messages.success_nodesc
      elsif task_status == 'success' && has_payload == true
        result = task_get_result(task_opaqueref['Value'])
        task_destroy(task_opaqueref['Value'])
        result['Value'] = xml_parse(result['Value'])
        result['Value']
      else
        error_info = task_get_error(task_opaqueref['Value'])['Value']
        task_destroy(task_opaqueref['Value'])
        Messages.error_unknown(error_info)
      end
    end
  end

  ##
  # Parse the last boot record to Hash.
  #
  # This parser is adapted from https://gist.github.com/ascendbruce/7070951
  def parse_last_boot_record(raw_last_boot_record)
    parsed = JSON.parse(raw_last_boot_record)
    # Also need to convert mess stuffs to Human-readable
    begin
      parsed['last_start_time'] = Time.at(parsed['last_start_time']).to_s
    rescue NoMethodError
      parsed['last_start_time'] = ''
    end
    parsed
  rescue JSON::ParserError
    # Ruby rescue is catch in other languages
    # Parsing struct is farrrrrrr too difficult
    Messages.error_unsupported
  end

  ##
  # XML Parser, important
  # https://github.com/savonrb/nori
  def xml_parse(raw_xml)
    xml_parser = Nori.new(parser: :rexml, convert_tags_to: ->(tag) { tag.snakecase })
    begin
      xml_parser.parse(raw_xml)
    rescue
      true
    end
  end

  ##
  # https://stackoverflow.com/questions/5661466/test-if-string-is-a-number-in-ruby-on-rails
  def number?(string)
    true if Integer(string)
  rescue Integer::ArgumentError
    false
  end
end
