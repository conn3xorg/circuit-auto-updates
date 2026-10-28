# circuit-auto-updates

A Conn3x circuit that keeps your hosts patched on their own. It sets up the package manager's own automatic updates, unattended-upgrades on Debian and Ubuntu and dnf's automatic updates on Fedora and Rocky Linux, and makes the settings you'd otherwise hand-edit on every box into a handful of inputs: security updates only or everything, whether to reboot, when, and which packages to leave alone.

The updates run from a systemd timer on each host, so they keep going whether or not you run Conn3x again. What Conn3x keeps in step is the configuration: if someone edits it or turns the timer off, the next `conn3x plan` shows it.

## Usage

```hcl
module "auto_updates" {
  source = "github.com/conn3xorg/circuit-auto-updates?ref=v0.1.0"

  hosts                = { web = "192.168.1.20", db = "192.168.1.21" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  security_only = true
  reboot        = "when-needed"
  reboot_time   = "04:30"
  schedule      = "*-*-* 03:00"
  exclude       = ["postgresql*"]
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

Each host installs updates at about 03:00 and, when one of them needs a reboot, such as a new kernel, reboots at 04:30. PostgreSQL is left for you to upgrade by hand.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry:

```hcl
hosts = {
  for name, d in digitalocean_droplet.app : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

Before the circuit runs, the `conn3x_host` data source reads each host's distribution over SSH. Then, on Debian and Ubuntu:

1. Installs `unattended-upgrades`.
2. Writes `/etc/apt/apt.conf.d/20auto-upgrades`, which turns on the daily package list refresh and the daily upgrade.
3. Writes `/etc/apt/apt.conf.d/52conn3x-unattended-upgrades`. It replaces the origins the package's own `50unattended-upgrades` allows with its own list, and sets the package blacklist and the reboot settings. `50unattended-upgrades` is left as the package shipped it.
4. Writes a drop-in for `apt-daily-upgrade.timer` with `schedule`, and enables and starts `apt-daily.timer` and `apt-daily-upgrade.timer`.

On Fedora and Rocky Linux:

1. Installs `dnf5-plugin-automatic` on Fedora, whose dnf is dnf5, or `dnf-automatic` on Rocky Linux 10, which still runs dnf4.
2. Writes `/etc/dnf/automatic.conf`. On Fedora, dnf5 reads its defaults from the package's file in `/usr/share` and this file on top. On Rocky Linux, this file replaces the one the package ships, and anything it doesn't set takes dnf's built-in default.
3. Writes a drop-in for `dnf5-automatic.timer` on Fedora or `dnf-automatic.timer` on Rocky Linux with `schedule`, and enables and starts the timer.

The settings map to each package manager like this:

| Input | unattended-upgrades | dnf automatic |
| --- | --- | --- |
| `security_only = true` | Origins: the release's `-security` suite, and on Ubuntu the ESM security archives | `upgrade_type = security` |
| `security_only = false` | Adds the release itself and its `-updates` suite | `upgrade_type = default` |
| `reboot` | `Automatic-Reboot`, which reboots when `/var/run/reboot-required` exists | `reboot = never` or `when-needed` |
| `reboot_time` | `Automatic-Reboot-Time` | `reboot_command = "shutdown -r HH:MM ..."`, whose outer quotes dnf strips |
| `exclude` | `Package-Blacklist`, each glob turned into an anchored regular expression | `excludepkgs` in `[base]` |

A host that needs a reboot waits for `reboot_time`, 04:00 unless you set it, rather than rebooting as soon as the updates finish.

The schedule drop-in is `conn3x-schedule.conf` in the timer's `.d` directory under `/etc/systemd/system`. It clears the timer's `OnCalendar` and sets yours. Before writing it, the circuit checks `schedule` with `systemd-analyze calendar` on the host, so a typo fails the apply rather than leaving the timer without a schedule. Without `schedule`, the drop-in holds only a comment and the timer keeps the distribution's: 06:00 for both apt-daily-upgrade and dnf automatic, plus a random delay of up to an hour on each.

All three timers have `Persistent=true`, so a run missed while the host was off happens soon after it's back. A new schedule takes effect with `systemctl daemon-reload`, which doesn't trigger a missed run. Restarting the timer would, so the circuit doesn't. Starting a stopped timer does trigger a missed run, so on a host where the timer ran before and was later stopped, the first apply can start an update during the day. With `reboot = "when-needed"`, any reboot it needs still waits for `reboot_time`.

### What it doesn't cover

- Third-party repositories. On Debian and Ubuntu, only the distribution's own origins are allowed, so packages from Docker's, PostgreSQL's or any other added repository aren't upgraded. On Fedora and Rocky Linux, dnf upgrades from every enabled repository.
- Notifications. Results go to the journal (`journalctl -u apt-daily-upgrade` or `journalctl -u dnf-automatic`); no email is sent.
- Rebooting after every update. `reboot = "when-needed"` reboots only when an update asks for it.
- Removing it. Deleting the module leaves the package, the configuration and the timer as they are.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `security_only` | bool | `true` | Install security updates only. Set it to `false` to install every update from the distribution's own repositories. |
| `reboot` | string | `"never"` | `"never"`, or `"when-needed"` to reboot when an update asks for it. |
| `reboot_time` | string | `"04:00"` | Time of day to reboot, as `HH:MM` in the host's time zone. Used when `reboot` is `"when-needed"`. |
| `schedule` | string | `null` | When the upgrade timer runs, as a systemd `OnCalendar` expression such as `"*-*-* 03:00"` or `"Sun 04:00"`. When null, the distribution's own schedule. |
| `exclude` | list(string) | `[]` | Packages never to update automatically, by name or glob, such as `["postgresql*", "linux-image-*"]`. |

## Outputs

| Name | Description |
| --- | --- |
| `timers` | The systemd timer that installs updates on each host, such as `{ web = "apt-daily-upgrade.timer", db = "dnf-automatic.timer" }`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host. Debian and Ubuntu hosts must be Debian or Ubuntu themselves, not a derivative, since the allowed origins name them. Hosts need to reach their package mirrors.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, that the upgrade timer is enabled, active and set to the example's schedule, and that the package manager reads the example's settings: with `apt-config dump` and an `unattended-upgrade --dry-run` on Debian and Ubuntu, and by reading `/etc/dnf/automatic.conf` back through dnf's own parser on Fedora and Rocky Linux, including the reboot command.

## License

MPL-2.0. See [LICENSE](LICENSE).
