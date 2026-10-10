source "lxd" "distcc" {
  image          = local.base_image
  output_image   = "distcc"
  container_name = "packer-distcc"
  init_sleep     = "5"
  publish_properties = {
    description = "distcc worker"
  }
}

build {
  name    = "distcc"
  sources = ["source.lxd.distcc"]

  # Compilers go in before distcc so its postinst allowlists them in
  # /usr/lib/distcc. Workers must run the same compiler versions as the
  # clients, so this tracks the release's default gcc/g++.
  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "cloud-init status --wait >/dev/null || true",
      "apt-get update",
      "apt-get -y install gcc g++",
      "apt-get -y install distcc",
      "update-distcc-symlinks",
    ]
  }

  provisioner "file" {
    source      = "files/etc/default/distcc"
    destination = "/etc/default/distcc"
  }

  provisioner "shell" {
    inline = ["mkdir -p /etc/systemd/system/distcc.service.d"]
  }

  provisioner "file" {
    source      = "files/etc/systemd/system/distcc.service.d/override.conf"
    destination = "/etc/systemd/system/distcc.service.d/override.conf"
  }

  # Smoke test: compile through distccd with local fallback disabled.
  provisioner "shell" {
    inline = concat([
      "set -e",
      "chmod 0644 /etc/default/distcc /etc/systemd/system/distcc.service.d/override.conf",
      "systemctl daemon-reload",
      "systemctl restart distcc",
      "sleep 1",
      # Every ALLOWEDNETS entry must reach distccd as its own --allow.
      "for net in $(. /etc/default/distcc && echo $ALLOWEDNETS); do tr '\\0' ' ' < /proc/$(pgrep -o distccd)/cmdline | grep -q -- \"--allow $net\"; done",
      "cd /tmp && printf 'int main(void) { return 0; }\\n' > hello.c",
      "DISTCC_HOSTS=127.0.0.1 DISTCC_FALLBACK=0 DISTCC_SKIP_LOCAL_RETRY=1 distcc gcc -c hello.c -o hello.o",
      "test -s hello.o && rm -r hello.c hello.o /root/.distcc",
      "gcc --version | head -1",
    ], local.image_cleanup)
  }
}
