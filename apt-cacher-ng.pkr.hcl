source "lxd" "apt-cacher-ng" {
  image          = local.base_image
  output_image   = "apt-cacher-ng"
  container_name = "packer-apt-cacher-ng"
  init_sleep     = "5"
  publish_properties = {
    description = "apt proxy"
  }
}

build {
  name    = "apt-cacher-ng"
  sources = ["source.lxd.apt-cacher-ng"]

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "cloud-init status --wait >/dev/null || true",
      # Keep LAN clients from discovering this short-lived build container as
      # their apt proxy. avahi stays enabled in the image.
      "systemctl stop avahi-daemon.socket avahi-daemon.service",
      "apt-get update",
      "apt-get -y install apt-cacher-ng",
    ]
  }

  # acng reads every *.conf in its config dir, so we only carry our overrides
  # and leave the packaged acng.conf alone.
  provisioner "file" {
    source      = "files/etc/apt-cacher-ng/zz-homelab.conf"
    destination = "/etc/apt-cacher-ng/zz-homelab.conf"
  }

  provisioner "shell" {
    inline = concat([
      "chmod 0644 /etc/apt-cacher-ng/zz-homelab.conf",
      "systemctl restart apt-cacher-ng",
      "sleep 2",
      # Fail the build if the proxy doesn't serve through our config.
      "curl -sf -o /dev/null -x http://127.0.0.1:3142 http://archive.ubuntu.com/ubuntu/dists/${var.ubuntu_release}/Release",
      "curl -sf http://127.0.0.1:3142/acng-report.html | grep -q 'Apt-Cacher NG'",
      # https tunnels work, other CONNECT targets are refused.
      "curl -sf -o /dev/null -x http://127.0.0.1:3142 https://archive.ubuntu.com/",
      # -p forces a CONNECT tunnel to port 80, which would succeed if allowed.
      "if curl -sf -p -o /dev/null --max-time 10 -x http://127.0.0.1:3142 http://archive.ubuntu.com/ubuntu/; then echo 'proxy tunnels non-443 ports' >&2; exit 1; fi",
    ], local.image_cleanup)
  }
}
