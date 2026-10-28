# Facts give each host's distribution: unattended-upgrades on Debian and
# Ubuntu, dnf's automatic updates on the Red Hat family.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  # unattended-upgrades picks updates by where they come from. Security
  # updates come from the -security suite; the rest come from the release
  # itself (Debian's point releases) and its -updates suite.
  origins = {
    debian = {
      security = [
        "origin=Debian,codename=$${distro_codename}-security,label=Debian-Security",
        "origin=Debian,codename=$${distro_codename},label=Debian-Security",
      ]
      other = [
        "origin=Debian,codename=$${distro_codename},label=Debian",
        "origin=Debian,codename=$${distro_codename}-updates",
      ]
    }
    ubuntu = {
      security = [
        "origin=Ubuntu,archive=$${distro_codename}-security",
        "origin=UbuntuESMApps,archive=$${distro_codename}-apps-security",
        "origin=UbuntuESM,archive=$${distro_codename}-infra-security",
      ]
      other = [
        "origin=Ubuntu,archive=$${distro_codename}",
        "origin=Ubuntu,archive=$${distro_codename}-updates",
      ]
    }
  }

  # Package-Blacklist takes regular expressions matched from the start of
  # the name, so each glob in exclude becomes one anchored at the end too.
  blacklist = [for p in var.exclude : "${replace(replace(replace(p, ".", "[.]"), "+", "[+]"), "*", ".*")}$"]

  apt_hosts = { for name, h in var.hosts : name => h if data.conn3x_host.facts[name].os_family == "debian" }
  dnf_hosts = { for name, h in var.hosts : name => h if data.conn3x_host.facts[name].os_family == "redhat" }

  apt = {
    for name, _ in local.apt_hosts : name => <<-EOT
      // Managed by Conn3x. Replaces the origins in 50unattended-upgrades.
      #clear Unattended-Upgrade::Allowed-Origins;
      #clear Unattended-Upgrade::Origins-Pattern;
      Unattended-Upgrade::Origins-Pattern {
      %{for o in concat(local.origins[data.conn3x_host.facts[name].os_id].security, var.security_only ? [] : local.origins[data.conn3x_host.facts[name].os_id].other)~}
        "${o}";
      %{endfor~}
      };
      Unattended-Upgrade::Package-Blacklist {
      %{for p in local.blacklist~}
        "${p}";
      %{endfor~}
      };
      Unattended-Upgrade::Automatic-Reboot "${var.reboot == "when-needed"}";
      Unattended-Upgrade::Automatic-Reboot-Time "${coalesce(var.reboot_time, "now")}";
    EOT
  }

  # Fedora runs dnf5, whose automatic plugin ships its own timer. Rocky
  # Linux 10 and the rest of EL10 still run dnf4's dnf-automatic.
  dnf = {
    for name, _ in local.dnf_hosts : name => data.conn3x_host.facts[name].os_id == "fedora" ? {
      package = "dnf5-plugin-automatic"
      timer   = "dnf5-automatic.timer"
      } : {
      package = "dnf-automatic"
      timer   = "dnf-automatic.timer"
    }
  }

  # dnf reads its defaults from the package, then this file.
  dnf_conf = <<-EOT
    # Managed by Conn3x.
    [commands]
    upgrade_type = ${var.security_only ? "security" : "default"}
    download_updates = yes
    apply_updates = yes
    reboot = ${var.reboot}
    reboot_command = "shutdown -r ${coalesce(var.reboot_time, "+5")} 'Rebooting after applying package updates'"

    [emitters]
    emit_via = stdio

    [base]
    excludepkgs = ${join(",", var.exclude)}
  EOT

  # A drop-in that replaces the timer's OnCalendar. Without schedule, it
  # holds only a comment and the timer keeps the distribution's schedule.
  schedule = var.schedule == null ? "# Managed by Conn3x. No schedule set; the timer keeps its own.\n" : "# Managed by Conn3x.\n[Timer]\nOnCalendar=\nOnCalendar=${var.schedule}\n"
}

circuit "apt" {
  hosts = local.apt_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "package" {
    package {
      name = "unattended-upgrades"
    }
  }

  step "periodic" {
    file {
      path    = "/etc/apt/apt.conf.d/20auto-upgrades"
      content = "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";\n"
    }
  }

  step "config" {
    file {
      path    = "/etc/apt/apt.conf.d/52conn3x-unattended-upgrades"
      content = local.apt[each.key]
    }
  }

  # Fails before the drop-in is written if systemd can't parse schedule,
  # which would otherwise leave the timer without a schedule.
  step "schedule_valid" {
    for_each = toset(var.schedule == null ? [] : [var.schedule])
    command {
      command = "echo 'schedule is not a calendar expression systemd understands: ${item.value}' >&2; exit 1"
      unless  = "systemd-analyze calendar '${item.value}' >/dev/null"
    }
  }

  step "schedule_dir" {
    directory {
      path = "/etc/systemd/system/apt-daily-upgrade.timer.d"
    }
  }

  step "schedule" {
    file {
      path    = "/etc/systemd/system/apt-daily-upgrade.timer.d/conn3x-schedule.conf"
      content = local.schedule
    }
  }

  # systemd reads the drop-in on daemon-reload, and the timer takes the new
  # schedule when it restarts.
  step "schedule_applied" {
    command {
      command  = "systemctl daemon-reload && systemctl restart apt-daily-upgrade.timer"
      triggers = { schedule = conn3x_file.apt__schedule[each.key].revision }
    }
  }

  # apt-daily refreshes the package lists; apt-daily-upgrade installs.
  step "timers" {
    for_each = toset(["apt-daily.timer", "apt-daily-upgrade.timer"])
    service {
      name    = item.value
      state   = "started"
      enabled = true
    }
  }
}

circuit "dnf" {
  hosts = local.dnf_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "package" {
    package {
      name = local.dnf[each.key].package
    }
  }

  step "config" {
    file {
      path    = "/etc/dnf/automatic.conf"
      content = local.dnf_conf
    }
  }

  step "schedule_valid" {
    for_each = toset(var.schedule == null ? [] : [var.schedule])
    command {
      command = "echo 'schedule is not a calendar expression systemd understands: ${item.value}' >&2; exit 1"
      unless  = "systemd-analyze calendar '${item.value}' >/dev/null"
    }
  }

  step "schedule_dir" {
    directory {
      path = "/etc/systemd/system/${local.dnf[each.key].timer}.d"
    }
  }

  step "schedule" {
    file {
      path    = "/etc/systemd/system/${local.dnf[each.key].timer}.d/conn3x-schedule.conf"
      content = local.schedule
    }
  }

  step "schedule_applied" {
    command {
      command  = "systemctl daemon-reload && systemctl restart ${local.dnf[each.key].timer}"
      triggers = { schedule = conn3x_file.dnf__schedule[each.key].revision }
    }
  }

  step "timer" {
    service {
      name    = local.dnf[each.key].timer
      state   = "started"
      enabled = true
    }
  }
}
