source "lxd" "base" {
  image          = "ubuntu:${var.ubuntu_release}"
  output_image   = local.base_image
  container_name = "packer-${local.base_image}"
  profile        = var.build_profile
  init_sleep     = "5"
  publish_properties = {
    description = "rsyslog, unattended-upgrades, apt mirror, etc"
  }
}

build {
  name    = "base"
  sources = ["source.lxd.base"]

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "cloud-init status --wait >/dev/null || true",
      "apt-get update",
      "apt-get -y full-upgrade",
      # squid-deb-proxy-client finds apt-cacher-ng over mDNS (avahi).
      "apt-get -y install avahi-daemon squid-deb-proxy-client rsyslog unattended-upgrades",
      # The container clock comes from the host. Ubuntu's chrony can't run in a
      # container, and its chrony-wait stalls boot (and every calendar timer,
      # e.g. apt-daily) for 3 minutes. Something must still provide
      # time-daemon for ubuntu-minimal, so swap in systemd-timesyncd, which
      # skips itself in containers; otherwise apt picks ntpsec.
      "apt-get -y purge snapd chrony systemd-timesyncd+",
      "apt-get -y autoremove --purge",
      "if dpkg -l chrony ntpsec ntp 2>/dev/null | grep -q '^ii'; then echo 'a time daemon is installed' >&2; exit 1; fi",
    ]
  }

  provisioner "file" {
    source      = "files/etc/rsyslog.d/90-remote.conf"
    destination = "/etc/rsyslog.d/90-remote.conf"
  }

  provisioner "shell" {
    inline = concat([
      "chmod 0644 /etc/rsyslog.d/90-remote.conf",
      "rsyslogd -N1",
      # We use `lxc exec`, not `lxc console`, and LXD's /dev/console often isn't
      # ready when agetty starts, which leaves every container "degraded".
      "systemctl mask console-getty.service",
      # Nor ssh: the image has no keys or passwords, so sshd is only attack
      # surface. Unmask ssh.socket in a container that needs it.
      "systemctl mask ssh.socket ssh.service",
    ], local.image_cleanup)
  }
}
