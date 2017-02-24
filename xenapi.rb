#!/usr/bin/env ruby

require 'json'
require 'nori'
require 'openssl'
require 'xmlrpc/client'
require './messages.rb'

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
  def initialize(server_path, server_port = 443, username = 'root', password)
    # This is where the connection is made
    # https://stelfox.net/blog/2012/02/rubys-xmlrpc-client-and-ssl/
    connection_param = {
      host: server_path,
      port: server_port,
      use_ssl: true,
      path: '/'
    }
    @connect = XMLRPC::Client.new_from_hash(connection_param)
    # This is the SSL Check Bypassing Mechanism
    @connect.http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @session = @connect.call('session.login_with_password', username, password)['Value']
  end

  ##
  # Logout
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
    all_records = @connect.call('VM.get_all', @session)['Value']
    # Filter Away Control Domain
    no_dom0 = all_records.select do |vm_opaqueref|
      !check_vm_entity_is_dom0(vm_opaqueref)
    end
    # Filter Away Template
    filtered = no_dom0.select do |vm_opaqueref|
      !check_vm_entity_is_template(vm_opaqueref)
    end
    Messages.success_nodesc_with_payload(filtered)
  end

  ##
  # Get all Templates
  #
  # +pv+:: Paravirtual Templates Only?
  def vm_list_all_templates(pv)
    all_records = @connect.call('VM.get_all', @session)['Value']
    # Filter Away non-template (VM Instances + dom0)
    all_templates = all_records.select do |tpl_opaqueref|
      check_vm_entity_is_template(tpl_opaqueref)
    end
    if pv == true
      all_templates = all_templates.select do |tpl_opaqueref|
        check_vm_entity_is_paravirtual(tpl_opaqueref)
      end
    end
    Messages.success_nodesc_with_payload(all_templates)
  end

  ##
  # Get Virtual Machines Detail by OpaqueRef
  #
  # +vm_opaqueref+:: VM Reference
  def vm_get_record(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      record = @connect.call('VM.get_record', @session, vm_opaqueref)['Value']
      # Post processing
      # 1. Decode Time Object to Human-readable
      begin
        record['snapshot_time'] = record['snapshot_time'].to_time.to_s
      rescue NoMethodError
        true
      end
      # 2. Last Boot Record is JSON, decode to Ruby Hash so that it won't clash
      #    the JSON generator
      record['last_booted_record'] = parse_last_boot_record(record['last_booted_record'])
      # 3. Parse Recommendations into Hash, using oga
      record['recommendations'] = xml_parse(record['recommendations'])
      # Output. return is redundant in Ruby World.
      Messages.success_nodesc_with_payload(record)
    end
  end

  ##
  # Get Virtual Machines Detail by OpaqueRef
  #
  # +vm_opaqueref+:: VM Reference
  def vm_get_template_record(vm_opaqueref)
    if check_vm_entity_is_nonexist(vm_opaqueref) || check_vm_entity_is_dom0(vm_opaqueref) || vm_opaqueref == '' || vm_opaqueref.nil?
      Messages.error_not_permitted
    else
      record = @connect.call('VM.get_record', @session, vm_opaqueref)['Value']
      record['recommendations'] = xml_parse(record['recommendations'])
      record['other_config']['disks'] = xml_parse(record['other_config']['disks'])
      begin
        record['snapshot_time'] = record['snapshot_time'].to_time.to_s
      rescue NoMethodError
        record['snapshot_time'] = nil
      end
      # Output. return is redundant in Ruby World.
      Messages.success_nodesc_with_payload(record)
    end
  end

  ##
  # Get Various Physical Details about the VM
  #
  # +vm_opaqueref+:: VM Reference
  def vm_get_metrics(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_metrics', @session, vm_opaqueref)['Value']
      dat = @connect.call('VM_metrics.get_record', @session, ref)
      # convert mess stuffs to Human-readable
      begin
        dat['Value']['start_time']   = dat['Value']['last_updated'].to_time.to_s
        dat['Value']['install_time'] = dat['Value']['last_updated'].to_time.to_s
        dat['Value']['last_updated'] = dat['Value']['last_updated'].to_time.to_s
      rescue NoMethodError
        dat['Value']['start_time']   = nil
        dat['Value']['install_time'] = nil
        dat['Value']['last_updated'] = nil
      end
      # Output. return is redundant in Ruby World.
      dat
    end
  end

  ##
  # Get Various Runtime Detail about the VM
  #
  # +vm_opaqueref+:: VM Reference
  def vm_get_guest_metrics(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_guest_metrics', @session, vm_opaqueref)['Value']
      dat = @connect.call('VM_guest_metrics.get_record', @session, ref)
      # convert mess stuffs to Human-readable
      begin
        dat['Value']['last_updated'] = dat['last_updated'].to_time.to_s
      rescue NoMethodError
        dat['Value']['last_updated'] = nil
      end
      # Output. return is redundant in Ruby World.
      dat
    end
  end

  # Get VM Network IPs
  # http://discussions.citrix.com/topic/244784-how-to-get-ip-address-of-vm-network-adapters/
  #
  # +vm_opaqueref+:: VM Reference
  def vm_get_guest_metrics_network(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      ref = @connect.call('VM.get_guest_metrics', @session, vm_opaqueref)['Value']
      @connect.call('VM_guest_metrics.get_networks', @session, ref)
    end
  end

  ##
  # Get Block Devices of the specified VM
  #
  # +vm_opaqueref+:: VM Reference
  def vm_get_vbds(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.get_VBDs', @session, vm_opaqueref)
    end
  end

  ##
  # Get Virtual Network Interfaces (VIFs) of the specified VM
  #
  # +vm_opaqueref+:: VM Reference
  def vm_get_vifs(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.get_VIFs', @session, vm_opaqueref)
    end
  end

  ##
  # Power ON the specified Virtual Machine
  #
  # +vm_opaqueref+:: VM Reference
  def vm_power_on(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      task_token = @connect.call('Async.VM.start', @session, vm_opaqueref, false, false)
      async_task_manager(task_token, false)
    end
  end

  ##
  # Power OFF the specified Virtual Machine
  #
  # +vm_opaqueref+:: VM Reference
  def vm_power_off(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      task_token = @connect.call('Async.VM.shutdown', @session, vm_opaqueref)
      async_task_manager(task_token, false)
    end
  end

  ##
  # Reboot the specified Virtual Machines
  #
  # +vm_opaqueref+:: VM Reference
  def vm_power_reboot(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      task_token = @connect.call('Async.VM.hard_reboot', @session, vm_opaqueref)
      async_task_manager(task_token, false)
    end
  end

  ##
  # Suspend the specified Virtual Machine
  #
  # +vm_opaqueref+:: VM Reference
  def vm_power_pause(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      # API Manual P116
      # void suspend (session_id s, VM ref vm)
      task_token = @connect.call('Async.VM.suspend', @session, vm_opaqueref)
      async_task_manager(task_token, false)
    end
  end

  ##
  # Wake up the specified Virtual Machine
  #
  # +vm_opaqueref+:: VM Reference
  def vm_power_unpause(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      # API Manual P116-117
      # void resume (session_id s, VM ref vm, bool start_paused, bool force)
      task_token = @connect.call('Async.VM.resume', @session, vm_opaqueref, false, false)
      async_task_manager(task_token, false)
    end
  end

  ##
  # Clone the target Virtual Machine
  # Returns the reference point of new vm
  # APIDoc P111, Copy tends to be more guaranteed.
  #
  # +old_vm_opaqueref+:: Source VM Identifier
  # +new_vm_name+     :: Name of the new VM
  # Returns:
  # the record of new vm
  def vm_clone(old_vm_opaqueref, new_vm_name)
    if check_vm_entity_validity(old_vm_opaqueref) || new_vm_name.nil? || new_vm_name == ''
      Messages.error_not_permitted
    else
      # The NULL Reference is required to fulfill the requirement.
      task_token = @connect.call('Async.VM.copy', @session, old_vm_opaqueref, new_vm_name, 'OpaqueRef:NULL')
      result = async_task_manager(task_token, true)
      if result.key?('Status') && result['Status'] == 'Error'
        result
      else
        Messages.success_nodesc_with_payload(result['value'])
      end
    end
  end

  ##
  # Clone from PV Template
  # TODO: Test Required
  #
  # +vm_tpl_opaqueref+:: Source Template Identifier
  # +new_vm_name+          :: Name of the new VM
  # +pv_boot_param+        :: Boot Command Line
  # +repo_url+             :: URL of the Distro Repo
  # +distro+               :: Distro Family, acceptable values are _debian_ and _rhel_
  # +distro_release+       :: Release Name of the specified Debian/Ubuntu Release. example: _jessie_(Debian 8), _trusty_(Ubuntu 14.04)
  # Returns:
  # the record of new vm
  def vm_clone_from_template(vm_tpl_opaqueref, new_vm_name, pv_boot_param, repo_url, distro, distro_release, net_opaqueref)
    if check_vm_template_validity(vm_tpl_opaqueref) || new_vm_name.nil? || new_vm_name == ''
      Messages.error_not_permitted
    else
      # Step0.1: Copy from template.
      # The NULL Reference is required to fulfill the params requirement.
      task_token = @connect.call('Async.VM.copy', @session, vm_tpl_opaqueref, new_vm_name, 'OpaqueRef:NULL')
      # Step0.2: get new vm reference point
      result = async_task_manager(task_token, true)['value']
      # Step 1 : Set boot paramaters, For configuring the kickstart definition
      @connect.call('VM.set_PV_args', @session, result, pv_boot_param)
      # Step 2 : Set repository URL, important for install
      #          Always skip step if previous step has error
      #     2.1: Handling Debian-based
      if distro == 'debian'
        # Set New Value
        s = vm_set_other_config(result, 'debian-release', distro_release)
        s = vm_set_other_config(result, 'install-repository', repo_url) unless s['Status'] != 'Success'
        #     2.2: Handling EL (RH-related, like Fedora, CentOS, RHEL)
      elsif distro == 'rhel' || distro == 'sle'
        s = vm_set_other_config(result, 'install-repository', repo_url)
      # Other distro is HVM so we ignore it.
      else
        Messages.error_unsupported
      end
      if s['Status'] == 'Error'
        Messages.error_unknown(s['ErrorDescription'])
      else
        s = vif_create(result, net_opaqueref, 0)
        if s['Status'] == 'Error'
          Messages.error_unknown(s['ErrorDescription'])
        else
          # callback the new vm OpaqueRef
          Messages.success_nodesc_with_payload(result)
        end
      end
    end
  end

  ##
  # Erase the target Virtual Machine, along with related VDIs
  #
  # +old_vm_opaqueref+:: VM Identifier
  def vm_destroy(old_vm_opaqueref)
    if check_vm_entity_validity(old_vm_opaqueref)
      Messages.error_not_permitted
    else
      # Get /dev/xvda VDI Reference Code First.
      vbd_sets = vm_get_vbds(old_vm_opaqueref)['Value']
      xvda_id = ''
      vbd_sets.each do |vbd_opaqueref|
        record = vbd_get_detail(vbd_opaqueref)['Value']
        next if record['type'] != 'Disk' || record['device'] != 'xvda'
        xvda_id = record['VDI']
      end
      # Delete VM
      task_token = @connect.call('Async.VM.destroy', @session, old_vm_opaqueref)
      result = async_task_manager(task_token, false)
      if result['Status'] == 'Success'
        # Delete VM OK => Cleanup residue: /dev/xvda VDI
        vdi_destroy(xvda_id)
      else
        # Prompt Error on Deleting VM
        result
      end
    end
  end

  ##
  # Add "other config", useful for official PV Instance template
  #
  # +vm_opaqueref+:: VM Identifier
  # +key+         :: Config Key
  # +value+       :: Config Value
  def vm_add_other_config(vm_opaqueref, key, value)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.add_to_other_config', @session, vm_opaqueref, key, value)
    end
  end

  ##
  # Unset "other config", useful for official PV Instance template
  #
  # +vm_opaqueref+:: VM Identifier
  # +key+         :: Config Key
  def vm_rm_other_config(vm_opaqueref, key)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.remove_from_other_config', @session, vm_opaqueref, key)
    end
  end

  ##
  # Get other_config field.
  #
  # +vm_opaqueref+:: VM Identifier
  def vm_get_other_config(vm_opaqueref)
    record = vm_get_record(vm_opaqueref)
    if record['Status'] != 'Success'
      record
    else
      Messages.success_nodesc_with_payload(record['Value']['other_config'])
    end
  end

  ##
  # Set "other config", useful for official PV Instance template
  #
  # +vm_opaqueref+:: VM Identifier
  # +key+         :: Config Key
  # +value+       :: Config Value
  def vm_set_other_config(vm_opaqueref, key, value)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.add_to_other_config', @session, vm_opaqueref, key.to_s => value.to_s)
    end
  end

  ##
  # Add a tag to the specified VM
  #
  # +vm_opaqueref+:: VM Identifier
  # +tag+         :: Tag
  def vm_add_tag(vm_opaqueref, tag)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.add_tags', @session, vm_opaqueref, tag)
    end
  end

  ##
  # Unset VM tags
  #
  # +vm_opaqueref+:: VM Identifier
  # +tag+         :: Tag
  def vm_rm_tag(vm_opaqueref, tag)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.remove_tags', @session, vm_opaqueref, tag)
    end
  end

  ##
  # Get VM tags
  #
  # +vm_opaqueref+:: VM Identifier
  # +tag+         :: Tag
  # Returns:
  # Tags
  def vm_get_tags(vm_opaqueref)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.get_tags', @session, vm_opaqueref)
    end
  end

  ##
  # search VM by tag
  #
  # +tag+         :: Tag
  # Returns:
  # Matched VM
  def vm_search_by_tag(tag)
    all_vm = vm_list_all
    all_vm['Value'].select do |vm_opaqueref|
      vm_get_tags(vm_opaqueref)['Value'].include?(tag)
    end
  end

  ##
  # Set VM Name
  # +vm_opaqueref+:: VM OpaqueRef
  # +vm_name+:: VM Name
  def vm_set_name(vm_opaqueref, vm_name)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VM.set_name_label', @session, vm_opaqueref, vm_name)
    end
  end

  ##
  # Set VM Memory Size
  # +vm_opaqueref+:: VM OpaqueRef
  # +max_size+:: Memory Capacity
  # +min_size+:: Memory Baseline
  # ---
  # XMLRPC Library only accepts 32-bit SignedInt
  # 2147483648 (2GB actual value) will cause
  # RuntimeError: Integer is too big! Must be signed 32-bit integer!
  # WHAT THE HELL.
  # ---
  def vm_set_max_ram(vm_opaqueref, max_size)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      begin
        @connect.call('VM.set_memory_static_max', @session, vm_opaqueref, max_size.to_i)
        @connect.call('VM.set_memory_dynamic_max', @session, vm_opaqueref, max_size.to_i)
      rescue RuntimeError
        Messages.error_unsupported
      end
    end
  end
  #---
  # Collection: Task
  #---

  ##
  # All Task
  def list_task_all_records
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
    all_records = @connect.call('VDI.get_all', @session)['Value']
    # Filter Away Snapshots
    no_snapshot = all_records.select do |vdi_opaqueref|
      !check_vdi_is_a_snapshot(vdi_opaqueref)
    end
    # Filter Away XS-Tools
    filtered = no_snapshot.select do |vdi_opaqueref|
      !check_vdi_is_xs_iso(vdi_opaqueref)
    end
    filtered = filtered.select do |vdi_opaqueref|
      !check_vdi_is_iso(vdi_opaqueref) unless iso_cd == 'exclude'
      check_vdi_is_iso(vdi_opaqueref) unless iso_cd == 'only'
      true unless iso_cd == 'include'
    end
    Messages.success_nodesc_with_payload(filtered)
  end

  ##
  # Get a list of all Snapshot VDI
  def vdi_list_snapshot
    all_records = @connect.call('VDI.get_all', @session)['Value']
    # Filter Away Snapshots
    filtered = all_records.select do |vdi_opaqueref|
      check_vdi_is_a_snapshot(vdi_opaqueref)
    end
    Messages.success_nodesc_with_payload(filtered)
  end

  ##
  # Get XS-TOOLS VDI
  def vdi_list_tools
    all_records = @connect.call('VDI.get_all', @session)['Value']
    # Filter Away all butXS-Tools
    filtered = all_records.select do |vdi_opaqueref|
      check_vdi_is_xs_iso(vdi_opaqueref)
    end
    Messages.success_nodesc_with_payload(filtered)
  end

  ##
  # Get detail of the specified VDI
  #
  # +vdi_opaqueref+:: VDI Reference
  def vdi_get_record(vdi_opaqueref)
    if check_vdi_entity_validity(vdi_opaqueref)
      Messages.error_not_permitted
    else
      record = @connect.call('VDI.get_record', @session, vdi_opaqueref)
      begin
        record['Value']['snapshot_time'] = record['Value']['snapshot_time'].to_time.to_s
      rescue NoMethodError
        true
      end
      record
    end
  end

  ##
  # Resize the specified VDI
  #
  # +vdi_opaqueref+:: VDI Reference
  # +new_vdi_size+:: New Size of the VDI
  # FIXME: This is broken by the limitations of XMLRPC Library
  def vdi_resize(vdi_opaqueref, new_vdi_size)
    if check_vdi_entity_validity(vdi_opaqueref)
      Messages.error_not_permitted
    else
      begin
        @connect.call('VDI.resize_online', @session, vdi_opaqueref, new_vdi_size)
      rescue RuntimeError
        Messages.error_unsupported
      end
    end
  end

  ##
  # Destroy the specified VDI
  #
  # +vdi_opaqueref+:: VDI Reference
  def vdi_destroy(vdi_opaqueref)
    if check_vdi_entity_validity(vdi_opaqueref)
      Messages.error_not_permitted
    else
      vdi_task_token = @connect.call('Async.VDI.destroy', @session, vdi_opaqueref)
      async_task_manager(vdi_task_token, false)
    end
  end

  ##
  # Add a tag to the specified VDI
  #
  # +vdi_opaqueref+:: VDI Identifier
  # +tag+          :: Tag
  def vdi_add_tag(vdi_opaqueref, tag)
    if check_vdi_entity_validity(vdi_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VDI.add_tags', @session, vdi_opaqueref, tag)
    end
  end

  ##
  # Unset VDI tags
  #
  # +vdi_opaqueref+:: VDI Identifier
  # +tag+          :: Tag
  def vdi_rm_tag(vdi_opaqueref, tag)
    if check_vdi_entity_validity(vdi_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VDI.remove_tags', @session, vdi_opaqueref, tag)
    end
  end

  ##
  # get VDI tags
  #
  # +vdi_opaqueref+:: VDI Identifier
  # +tag+          :: Tag
  # Returns:
  # Tags
  def vdi_get_tags(vdi_opaqueref)
    if check_vdi_entity_validity(vdi_opaqueref)
      Messages.error_not_permitted
    else
      @connect.call('VDI.get_tags', @session, vdi_opaqueref)
    end
  end

  ##
  # Search VDI by tag
  # +tag+         :: Tag
  # Returns Matched VM
  def vdi_search_by_tag(tag)
    all_vdi = vdi_list('include')['Value']
    result = all_vdi.select do |vdi_opaqueref|
      vdi_get_tags(vdi_opaqueref)['Value'].include?(tag)
    end
    Messages.success_nodesc_with_payload(result)
  end

  #---
  # Collection: VBD (Virtual Block Devices)
  # TODO: Documentation, but usually VBD is lessly used
  #---

  ##
  # Get all VBD on the system
  def vbd_list
    @connect.call('VBD.get_all', @session)
  end

  ##
  # Get detail of the specified VBD
  def vbd_get_detail(vbd_opaqueref)
    @connect.call('VBD.get_record', @session, vbd_opaqueref)
  end

  ##
  # Create a Virtual Block Device (Plugged Instantly)
  #
  # +vm_opaqueref+:: VM Reference
  # +vdi_opaqueref+:: VDI Reference
  # +device_slot+:: VBD Device place
  def vbd_create(vm_opaqueref, vdi_opaqueref, device_slot)
    vbd_object = {
      VM: vm_opaqueref,
      VDI: vdi_opaqueref,
      userdevice: device_slot,
      bootable: false,
      mode: 'RW',
      type: 'Disk',
      empty: false,
      qos_algorithm_type: '', # TODO!
      qos_algorithm_params: '' # TODO!
    }
    @connect.call('VBD.create', @session, vbd_object)
  end

  #---
  # Collection: VIF (Virtual Network Interface)
  #---

  ##
  # List all VIF
  def vif_list
    @connect.call('VIF.get_all', @session)
  end

  ##
  # Get details of the specified VIF
  # +vif_opaqueref+:: OpaqueRef of the VIF
  def vif_get_detail(vif_opaqueref)
    @connect.call('VIF.get_record', @session, vif_opaqueref)
  end

  ##
  # Create a VIF
  # +vm_opaqueref+:: OpaqueRef of target VM
  # +net_opaqueref+:: Network to be plugged
  # +slot+:: Where the VIF is "inserted"
  def vif_create(vm_opaqueref, net_opaqueref, slot)
    if check_vm_entity_validity(vm_opaqueref)
      Messages.error_not_permitted
    else
      vbd_object = {
        device: slot.to_i,
        network: net_opaqueref,
        VM: vm_opaqueref,
        MAC: random_mac,
        MTU: 1500,
        other_config: {},
        qos_algorithm_type: '', # TODO!
        qos_algorithm_params: '' # TODO!
      }
      @connect.call('VIF.create', @session, vbd_object)
    end
  end

  ##
  # Destroy the specified VIF
  # +vif_opaqueref+:: OpaqueRef of the VIF
  def vif_destroy(vif_opaqueref)
    @connect.call('VIF.destroy', @session, vif_opaqueref)
  end

  ##
  # Plug the VIF
  # +vif_opaqueref+:: OpaqueRef of the VIF
  def vif_plug(vif_opaqueref)
    @connect.call('VIF.plug', @session, vif_opaqueref)
  end

  ##
  # UnPlug the VIF
  # +vif_opaqueref+:: OpaqueRef of the VIF
  def vif_unplug(vif_opaqueref)
    @connect.call('VIF.unplug', @session, vif_opaqueref)
  end

  #---
  # NET
  #---

  ##
  # List all network
  def network_list
    @connect.call('network.get_all', @session)
  end

  ##
  # Get details of the network
  def network_get_detail(network_opaqueref)
    @connect.call('network.get_record', @session, network_opaqueref)
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
    @connect.call('network.create', @session, vbd_object)
  end

  ##
  # Destroy a Internal Network
  # +network_opaqueref+:: OpaqueRef of the Network
  def network_destroy(network_opaqueref)
    @connect.call('network.destroy', @session, network_opaqueref)
  end

  ##
  # Tag a network
  # +network_opaqueref+:: OpaqueRef of the Network
  # +tag+:: the name tag
  def network_add_tag(network_opaqueref, tag)
    @connect.call('network.add_tags', @session, network_opaqueref, tag)
  end

  ##
  # UNTag a network
  # +network_opaqueref+:: OpaqueRef of the Network
  # +tag+:: the name tag
  def network_rm_tag(network_opaqueref, tag)
    @connect.call('network.remove_tags', @session, network_opaqueref, tag)
  end

  ##
  # Get Tags of network
  # +network_opaqueref+:: OpaqueRef of the Network
  def network_get_tags(network_opaqueref)
    @connect.call('network.get_tags', @session, network_opaqueref)
  end

  ##
  # Search network by Tag
  # +tag+:: the name tag
  def network_search_by_tag(tag)
    networks = network_list['Value']
    result = networks.select do |network_opaqueref|
      network_get_tags(network_opaqueref)['Value'].include?(tag)
    end
    Messages.success_nodesc_with_payload(result)
  end

  # Private Scope is intended for wrapping non-official and refactored functions

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
    # pygrub will be used after install finished
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
  # Filter: Check VDI Existency
  def check_vdi_entity_is_nonexist(vdi_opaqueref)
    result = @connect.call('VDI.get_uuid', @session, vdi_opaqueref)['Status']
    result == 'Success' ? false : true
  end

  #---
  # Aggregated Filters
  #---

  ##
  # Refactor: Aggregated Validity Check
  def check_vm_entity_validity(vm_opaqueref)
    check_vm_entity_is_nonexist(vm_opaqueref) || check_vm_entity_is_dom0(vm_opaqueref) || check_vm_entity_is_template(vm_opaqueref) || vm_opaqueref == '' || vm_opaqueref.nil?
  end

  ##
  # Refactor: Check Template Validity
  def check_vm_template_validity(vm_tpl_opaqueref)
    check_vm_entity_is_nonexist(vm_tpl_opaqueref) || check_vm_entity_is_dom0(vm_tpl_opaqueref) || !check_vm_entity_is_template(vm_tpl_opaqueref) || !check_vm_entity_is_paravirtual(vm_tpl_opaqueref) || vm_tpl_opaqueref == '' || vm_tpl_opaqueref.nil?
  end

  ##
  # Refactor: Aggregated VDI Validity Check
  def check_vdi_entity_validity(vdi_opaqueref)
    check_vdi_entity_is_nonexist(vdi_opaqueref) || check_vdi_is_a_snapshot(vdi_opaqueref) || check_vdi_is_xs_iso(vdi_opaqueref) || vdi_opaqueref == '' || vdi_opaqueref.nil?
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
  # You may say why don't I just put JSON.parse.
  # The main problem is some VM that uses maybe older XS Guest Additions
  # generates ('struct') instead of pretty JSON string
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
    # Parsing struct is farrrrrrr to difficult
    Messages.error_unsupported
  end

  ##
  # XML Parser, important
  # https://github.com/savonrb/nori
  def xml_parse(raw_xml)
    xml_parser = Nori.new(convert_tags_to: ->(tag) { tag.snakecase })
    xml_parser.parse(raw_xml)
  end

  # https://stackoverflow.com/questions/5661466/test-if-string-is-a-number-in-ruby-on-rails
  def number?(string)
    true if Integer(string)
  rescue Integer::ArgumentError
    false
  end

  # https://github.com/andrewgho/genmac
  def random_mac
    (1..6).collect { format('%02x', (rand 255)) }.join(':')
  end
end
