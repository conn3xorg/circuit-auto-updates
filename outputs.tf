output "timers" {
  description = "The systemd timer that installs updates on each host, by host name."
  value       = merge({ for name, _ in local.apt_hosts : name => "apt-daily-upgrade.timer" }, { for name, d in local.dnf : name => d.timer })
}
