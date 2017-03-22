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
    { 'Status' => 'Error', 'Description' => 'ACTION_NOT_DEFINED' }
  end

  def self.error_not_permitted
    { 'Status' => 'Error', 'Description' => 'ACTION_NOT_PERMITTED' }
  end

  def self.error_vm_bad_power_state
    { 'Status' => 'Error', 'Description' => 'VM_BAD_POWER_STATE' }
  end

  def self.error_try_later
    { 'Status' => 'Error', 'Description' => 'OTHER_OPERATION_IN_PROGRESS' }
  end

  def self.error_unsupported
    { 'Status' => 'Error', 'Description' => 'UNSUPPORTED' }
  end

  def self.error_unknown(error_string)
    { 'Status' => 'Error', 'Description' => error_string }
  end

  def self.error_unknown_with_payload(error_string, payload)
    { 'Status' => 'Error', 'Description' => error_string, 'Value' => payload }
  end

  def self.error_disk_full
    { 'Status' => 'Error', 'Description' => 'DISK_FULL_CONTACT_ADMINISTRATOR' }
  end

  #---
  # Good Messages
  #---
  def self.success_nodesc
    { 'Status' => 'Success', 'Description' => 'NO_DESCRIPTION' }
  end

  def self.success_nodesc_with_payload(payload)
    { 'Status' => 'Success', 'Description' => 'NO_DESCRIPTION', 'Value' => payload }
  end

  def self.success_custom_message(description)
    { 'Status' => 'Success', 'Description' => description, 'Value' => payload }
  end

  def self.success_custom_message_with_payload(description, payload)
    { 'Status' => 'Success', 'Description' => description, 'Value' => payload }
  end
end
