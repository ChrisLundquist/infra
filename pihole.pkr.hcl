source "lxd" "pihole" {
  image          = local.base_image
  output_image   = "pihole"
  container_name = "packer-pihole"
  init_sleep     = "5"
  publish_properties = {
    description = "pihole dns blocking"
  }
}

build {
  name    = "pihole"
  sources = ["source.lxd.pihole"]

  # unbound is Pi-hole's upstream (replaces cloudflared, whose proxy-dns
  # feature was removed in 2026.2.0).
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "cloud-init status --wait >/dev/null || true",
      "apt-get update",
      "apt-get -y install unbound bind9-dnsutils sqlite3",
      "mkdir -p /etc/pihole",
    ]
  }

  provisioner "file" {
    source      = "files/etc/unbound/unbound.conf.d/pi-hole.conf"
    destination = "/etc/unbound/unbound.conf.d/pi-hole.conf"
  }

  provisioner "file" {
    source      = "files/etc/unbound/forward-dot.conf"
    destination = "/tmp/forward-dot.conf"
  }

  # Both files are in place before the installer runs, so it takes the
  # unattended path with our settings and imports adlists.list into gravity.
  provisioner "file" {
    source      = "files/etc/pihole/pihole.toml"
    destination = "/etc/pihole/pihole.toml"
  }

  provisioner "file" {
    source      = "files/etc/pihole/adlists.list"
    destination = "/etc/pihole/adlists.list"
  }

  provisioner "file" {
    source      = "files/etc/pihole/allowlist.list"
    destination = "/etc/pihole/allowlist.list"
  }

  provisioner "file" {
    source      = "files/etc/systemd/system/pihole-gravity.service"
    destination = "/etc/systemd/system/pihole-gravity.service"
  }

  provisioner "file" {
    source      = "files/etc/systemd/system/pihole-gravity.timer"
    destination = "/etc/systemd/system/pihole-gravity.timer"
  }

  provisioner "shell" {
    environment_vars = ["DNS_UPSTREAM_MODE=${var.dns_upstream_mode}"]
    inline = [
      "set -e",
      "if [ \"$DNS_UPSTREAM_MODE\" = dot ]; then mv /tmp/forward-dot.conf /etc/unbound/unbound.conf.d/forward-dot.conf; else rm /tmp/forward-dot.conf; fi",
      "chmod 0644 /etc/unbound/unbound.conf.d/*.conf",
      # unbound-resolvconf would point the container's own resolv.conf at unbound.
      "systemctl mask --now unbound-resolvconf.service",
      "unbound-checkconf",
      "systemctl restart unbound",
      "dig +short +timeout=5 @127.0.0.1 -p 5335 example.com | grep -q .",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -e",
      "curl -sSfL -o /tmp/basic-install.sh https://install.pi-hole.net",
      "bash /tmp/basic-install.sh --unattended",
      "rm /tmp/basic-install.sh",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -e",
      "pihole -g",
      "grep -vE '^\\s*(#|$)' /etc/pihole/allowlist.list | xargs -r pihole allow -q --comment 'repo allowlist.list'",
      "chmod 0644 /etc/systemd/system/pihole-gravity.service /etc/systemd/system/pihole-gravity.timer",
      "systemctl daemon-reload",
      "systemctl enable pihole-gravity.timer",
    ]
  }

  # Smoke test: fail the build rather than publish a Pi-hole that can't
  # resolve (the v6 migration once left us with no upstreams at all).
  provisioner "shell" {
    inline = [
      "set -e",
      "pihole-FTL --config dns.upstreams | grep -q 127.0.0.1#5335",
      "dig +short +timeout=5 @127.0.0.1 example.com | grep -q .",
      "test \"$(dig +short +timeout=5 @127.0.0.1 pagead2.googlesyndication.com)\" = 0.0.0.0",
      # Repo allowlist entries resolve even though the lists block them.
      "dig +short +timeout=5 @127.0.0.1 osb.samsungqbe.com | grep -vq '^0.0.0.0$'",
      "dig +timeout=5 @127.0.0.1 dnssec-failed.org | grep -q 'status: SERVFAIL'",
      "dig +dnssec +timeout=5 @127.0.0.1 isc.org | grep -q 'flags:.* ad'",
      # No password: the API must accept us without logging in.
      "curl -sf http://127.0.0.1/api/auth | grep -q '\"valid\":true'",
    ]
  }

  # Don't ship the build's own query history.
  provisioner "shell" {
    inline = concat([
      "systemctl stop pihole-FTL",
      "rm -f /etc/pihole/pihole-FTL.db /etc/pihole/gravity_old.db /var/log/pihole/*.log",
    ], local.image_cleanup)
  }
}
