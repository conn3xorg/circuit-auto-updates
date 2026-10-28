#!/usr/bin/env sh
# Runs on the host: checks the upgrade timer is on and runs at the
# example's 03:00, and that the package manager reads the example's
# settings through its own parser. CI pipes it in with podman exec.
set -eu
if command -v apt-config >/dev/null; then
  t=apt-daily-upgrade.timer
  apt-config dump | grep -qx 'Unattended-Upgrade::Automatic-Reboot "true";'
  apt-config dump | grep -qx 'Unattended-Upgrade::Automatic-Reboot-Time "04:30";'
  apt-config dump | grep -q 'Origins-Pattern:: "origin=.*-updates"'
  unattended-upgrade --dry-run -d 2>&1 | grep -qF 'Initial blacklist: postgresql.*$ linux-image-.*$'
else
  # Read the settings back through dnf's own parser, so the quotes around
  # reboot_command are handled as dnf handles them.
  if command -v dnf5 >/dev/null; then
    t=dnf5-automatic.timer
    dnf -q -y install python3-libdnf5 >/dev/null 2>&1
    python3 -c '
import libdnf5
p = libdnf5.conf.ConfigParser()
p.read("/etc/dnf/automatic.conf")
print(p.get_value("commands", "reboot"))
print(p.get_value("commands", "reboot_command"))
print(p.get_value("base", "excludepkgs"))
' > /tmp/automatic.parsed
  else
    t=dnf-automatic.timer
    python3 -c '
import dnf, dnf.automatic.main
c = dnf.automatic.main.AutomaticConfig("/etc/dnf/automatic.conf")
b = dnf.Base()
c.update_baseconf(b.conf)
print(c.commands.reboot)
print(c.commands.reboot_command)
print(",".join(b.conf.excludepkgs))
' > /tmp/automatic.parsed
  fi
  printf '%s\n' when-needed "shutdown -r 04:30 'Rebooting after applying package updates'" 'postgresql*,linux-image-*' | diff - /tmp/automatic.parsed
fi
systemctl is-enabled "$t"
systemctl is-active "$t"
systemctl show -p TimersCalendar "$t" | grep -qF 'OnCalendar=*-*-* 03:00:00'
