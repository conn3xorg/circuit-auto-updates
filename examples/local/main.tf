variable "port" {
  type    = number
  default = 2222
}

module "auto_updates" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  security_only = false
  reboot        = "when-needed"
  reboot_time   = "04:30"
  schedule      = "*-*-* 03:00"
  exclude       = ["postgresql*", "linux-image-*"]
}

output "timers" {
  value = module.auto_updates.timers
}
