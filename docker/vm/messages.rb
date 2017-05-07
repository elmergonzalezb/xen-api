#!/usr/bin/env ruby

# Error messages
class Messages
  #---
  # Logic
  #---
  def self.error_switch(error_string)
    case error_string
    when 'VM_BAD_POWER_STATE'
      error_vm_bad_power_state
    when 'OTHER_OPERATION_IN_PROGRESS'
      error_try_later
    when 'OPERATION_NOT_ALLOWED' || 'VM IS TEMPLATE'
      error_not_permitted
    when 'SR_FULL'
      error_disk_full
    else
      error_unknown(error_string)
    end
  end

  #---
  # Bad Messages
  #---
  def self.error_undefined
    { 'Status' => 'Error', 'ErrorDescription' => ['ACTION_NOT_DEFINED'] }
  end

  def self.error_not_permitted
    { 'Status' => 'Error', 'ErrorDescription' => ['ACTION_NOT_PERMITTED'] }
  end

  def self.error_vm_bad_power_state
    { 'Status' => 'Error', 'ErrorDescription' => ['VM_BAD_POWER_STATE'] }
  end

  def self.error_try_later
    { 'Status' => 'Error', 'ErrorDescription' => ['OTHER_OPERATION_IN_PROGRESS'] }
  end

  def self.error_unsupported
    { 'Status' => 'Error', 'ErrorDescription' => ['UNSUPPORTED'] }
  end

  def self.error_unknown(error_string)
    { 'Status' => 'Error', 'ErrorDescription' => [error_string] }
  end

  def self.error_unknown_with_payload(error_string, payload)
    { 'Status' => 'Error', 'ErrorDescription' => [error_string], 'Value' => payload }
  end

  def self.error_disk_full
    { 'Status' => 'Error', 'ErrorDescription' => ['DISK_FULL_CONTACT_ADMINISTRATOR'] }
  end

  #---
  # Good Messages
  #---
  def self.success_nodesc
    { 'Status' => 'Success', 'Value' => '' }
  end

  def self.success_nodesc_with_payload(payload)
    { 'Status' => 'Success', 'Value' => payload }
  end

  def self.success_custom_message(Description)
    { 'Status' => 'Success', 'Value' => Description }
  end

  def self.success_custom_message_with_payload(_, payload)
    { 'Status' => 'Success', 'Value' => payload }
  end
end
