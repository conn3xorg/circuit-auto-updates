variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}



variable "security_only" {
  type        = bool
  default     = true
  description = "Install security updates only. Set it to false to install every update from the distribution's own repositories."
}

variable "reboot" {
  type        = string
  default     = "never"
  description = "When to reboot after updates: \"never\", or \"when-needed\" to reboot when an update asks for it, such as a new kernel."

  validation {
    condition     = contains(["never", "when-needed"], var.reboot)
    error_message = "reboot must be \"never\" or \"when-needed\"."
  }
}

variable "reboot_time" {
  type        = string
  default     = "04:00"
  description = "Time of day to reboot, as HH:MM in the host's time zone, when reboot is \"when-needed\"."

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.reboot_time))
    error_message = "reboot_time must be a 24-hour time such as \"04:30\"."
  }
}

variable "schedule" {
  type        = string
  default     = null
  description = "When the upgrade timer runs, as a systemd OnCalendar expression such as \"*-*-* 03:00\". When null, the distribution's own schedule."

  validation {
    condition     = var.schedule == null || can(regex("^[^\\n'\"\\\\]+$", coalesce(var.schedule, "-")))
    error_message = "schedule must be one line without quotes or backslashes, such as \"*-*-* 03:00\" or \"Sun 04:00\"."
  }
}

variable "exclude" {
  type        = list(string)
  default     = []
  description = "Packages never to update automatically, by name or glob, such as [\"postgresql*\"]."

  validation {
    condition     = alltrue([for p in var.exclude : can(regex("^[A-Za-z0-9*][A-Za-z0-9.+_*-]*$", p))])
    error_message = "Each of exclude must be a package name or a glob such as \"linux-image-*\"."
  }
}
