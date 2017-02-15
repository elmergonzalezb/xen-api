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
    { message: 'Error', description: 'ACTION_NOT_DEFINED' }
  end

  def self.error_not_permitted
    { message: 'Error', description: 'ACTION_NOT_PERMITTED' }
  end

  def self.error_vm_bad_power_state
    { message: 'Error', description: 'VM_BAD_POWER_STATE' }
  end

  def self.error_try_later
    { message: 'Error', description: 'OTHER_OPERATION_IN_PROGRESS' }
  end

  def self.error_unsupported
    { message: 'Error', description: 'UNSUPPORTED' }
  end

  def self.error_unknown(error_string)
    { message: 'Error', description: error_string }
  end

  def self.error_disk_full
    { message: 'Error', description: 'DISK_FULL_CONTACT_ADMINISTRATOR' }
  end

  #---
  # Good Messages
  #---
  def self.success_nodesc
    { message: 'Success', description: 'NO_DESCRIPTION' }
  end

  def self.success_nodesc_with_payload(payload)
    { message: 'Success', description: 'NO_DESCRIPTION', payload: payload }
  end
end
