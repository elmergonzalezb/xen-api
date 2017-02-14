#!/usr/bin/env ruby

require 'json'
require 'openssl'
require 'xmlrpc/client'

require_relative 'messages'

# XenApi Session Manager
class XenApi
  XEN_SERVER_ADDR = ENV['XEN_SERVER_ADDR']
  XEN_SERVER_PORT = ENV['XEN_SERVER_PORT'].empty? ? 443    : ENV['XEN_SERVER_PORT'].to_i
  XEN_SERVER_USER = ENV['XEN_SERVER_USER'].empty? ? 'root' : ENV['XEN_SERVER_USER']
  XEN_SERVER_PASS = ENV['XEN_SERVER_PASS']

  # Config Client
  def initialize
    # This is where the connection is made
    # https://stelfox.net/blog/2012/02/rubys-xmlrpc-client-and-ssl/
    connection_param = {
      host: XEN_SERVER_ADDR,
      port: XEN_SERVER_PORT,
      use_ssl: true,
      path: '/'
    }
    @connect = XMLRPC::Client.new_from_hash(connection_param)
    # This is the SSL Check Bypassing Mechanism
    @connect.http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    # Save the Session Key
    @session = @connect.call('session.login_with_password', XEN_SERVER_USER, XEN_SERVER_PASS)['Value']
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
      !check_is_template(opaqueref)
    end
    # Filter Away Control Domain
    no_template.select do |opaqueref|
      !check_is_controldomain(opaqueref)
    end
  end

  # Get Virtual Machines Detail by OpaqueRef
  # Translate all datetime to Human-readable stuffs
  def vm_record(opaqueref)
    if check_is_template(opaqueref) || check_is_template(opaqueref) || opaqueref == ''
      Messages.error_not_permitted
    else
      record = @connect.call('VM.get_record', @session, opaqueref)['Value']
      # Some post processing are needed
      # 1. Decode Time Object to Human-readable
      record['snapshot_time'] = record['snapshot_time'].to_time.to_s
      # 2. Last Boot Record is JSON, decode to Ruby Hash so that it won't clash the JSON generator
      record['last_booted_record'] = decode_last_boot_record(record['last_booted_record'])
      # Output. return is redundant in Ruby World.
      record
    end
  end

  # Switch On Virtual Machines
  def vm_power_on(opaqueref)
    if check_is_template(opaqueref) || check_is_template(opaqueref) || opaqueref == ''
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
    if check_is_template(opaqueref) || check_is_template(opaqueref) || opaqueref == ''
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
    if check_is_template(opaqueref) || check_is_template(opaqueref) || opaqueref == ''
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

  # Get Various Details about the VM
  # Also need to translate all datetime to Human-readable stuffs
  def inspect_vm(opaqueref)
    # http://discussions.citrix.com/topic/244784-how-to-get-ip-address-of-vm-network-adapters/
    if check_is_template(opaqueref) || check_is_template(opaqueref) || opaqueref == ''
      Messages.error_not_permitted
    else
      metric_ref = @connect.call('VM.get_guest_metrics', @session, opaqueref)['Value']
      metric_dat = @connect.call('VM_guest_metrics.get_record', @session, metric_ref)['Value']
      # convert mess stuffs to Human-readable
      metric_dat['last_updated'] = metric_dat['last_updated'].to_time.to_s
      metric_dat
    end
  end

  # Get VM Network IPs
  def inspect_vm_network(opaqueref, ip_version)
    if check_is_template(opaqueref) || check_is_template(opaqueref) || opaqueref == ''
      Messages.error_not_permitted
    else
      metric_ref = @connect.call('VM.get_guest_metrics', @session, opaqueref)['Value']
      metric_networks = @connect.call('VM_guest_metrics.get_networks', @session, metric_ref)['Value']
    end
    if ip_version == 4
      metric_networks['0/ip']
    elsif ip_version == 6
      metric_networks['0/ipv6/0']
    elsif ip_version == 'all'
      inspect_vm_detail(opaqueref)['networks']
    else
      Messages.error_undefined
    end
  end

  private

  def check_is_controldomain(opaqueref)
    @connect.call('VM.get_is_control_domain', @session, opaqueref)['Value']
  end

  def check_is_template(opaqueref)
    @connect.call('VM.get_is_a_template', @session, opaqueref)['Value']
  end

  # Parse the last boot record to Hash.
  # You may say why don't I just put JSON.parse.
  # The main problem is some VM that uses maybe older XS Guest Additions
  # generates ('struct') instead of pretty JSON string
  # This parser is adapted from https://gist.github.com/ascendbruce/7070951
  def decode_last_boot_record(raw_last_boot_record)
    parsed = JSON.parse(raw_last_boot_record)
    # Also need to convert mess stuffs to Human-readable
    parsed['last_start_time'] = Time.at(parsed['last_start_time']).to_s
  rescue JSON::ParserError
    # Ruby rescue is catch in other languages
    # Parsing struct is farrrrrrr to difficult
    Messages.error_unsupported
  end
end
