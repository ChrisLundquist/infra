packer {
  required_plugins {
    # We run our fork (github.com/ChrisLundquist/packer-plugin-lxd); see README.md
    # for installing it with `packer plugins install --path`.
    lxd = {
      source  = "github.com/hashicorp/lxd"
      version = ">= 1.0.0"
    }
  }
}

variable "ubuntu_release" {
  type        = string
  default     = "resolute"
  description = "Ubuntu codename used for the base image (pulled from the ubuntu: remote)."
}

variable "dns_upstream_mode" {
  type        = string
  default     = "recursive"
  description = "How unbound resolves: 'recursive' (talk to authoritative servers directly) or 'dot' (forward over DNS-over-TLS)."

  validation {
    condition     = contains(["recursive", "dot"], var.dns_upstream_mode)
    error_message = "The dns_upstream_mode must be 'recursive' or 'dot'."
  }
}

locals {
  base_image = "${var.ubuntu_release}-base"

  # Run last in every build so containers launched from the image get a fresh
  # machine-id (and thus their own DHCP DUID), a clean cloud-init run and no
  # build logs. The machine-id is left empty like Ubuntu's own images:
  # `cloud-init clean --machine-id` writes "uninitialized", which makes every
  # boot a systemd first boot (failed systemd-firstboot, presets re-applied).
  image_cleanup = [
    "apt-get clean",
    "cloud-init clean --logs --seed",
    "truncate -s 0 /etc/machine-id",
    "rm -f /var/lib/dbus/machine-id",
    "find /var/log -type f \\( -name '*.gz' -o -name '*.[0-9]' \\) -delete",
    "find /var/log -type f -exec truncate -s 0 {} +",
  ]
}
