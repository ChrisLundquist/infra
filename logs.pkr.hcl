source "lxd" "logs" {
  image          = local.base_image
  output_image   = "logs"
  container_name = "packer-logs"
  profile        = var.build_profile
  init_sleep     = "5"
  publish_properties = {
    description = "syslog sink for the LAN (logs.local)"
  }
}

build {
  name    = "logs"
  sources = ["source.lxd.logs"]

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline = [
      "cloud-init status --wait >/dev/null || true",
      "apt-get update",
      "apt-get -y install logrotate zstd",
      # This is logs.local, so don't forward its own logs to itself.
      "rm /etc/rsyslog.d/90-remote.conf",
    ]
  }

  provisioner "file" {
    source      = "files/etc/rsyslog.d/10-remote-server.conf"
    destination = "/etc/rsyslog.d/10-remote-server.conf"
  }

  provisioner "file" {
    source      = "files/etc/logrotate.d/remote-logs"
    destination = "/etc/logrotate.d/remote-logs"
  }

  provisioner "file" {
    source      = "files/etc/tmpfiles.d/remote-logs.conf"
    destination = "/etc/tmpfiles.d/remote-logs.conf"
  }

  # Smoke test: receive, rotate and compress, then expire.
  provisioner "shell" {
    inline = concat([
      "set -e",
      "chmod 0644 /etc/rsyslog.d/10-remote-server.conf /etc/logrotate.d/remote-logs /etc/tmpfiles.d/remote-logs.conf",
      "systemd-tmpfiles --create /etc/tmpfiles.d/remote-logs.conf",
      "rsyslogd -N1",
      "systemctl restart rsyslog",
      "sleep 1",
      # Messages over UDP and TCP land in <host>/<program>.log.
      "logger -n 127.0.0.1 -P 514 --udp -t buildcheck via-udp",
      "logger -n 127.0.0.1 -P 514 --tcp -t buildcheck via-tcp",
      "sleep 2",
      "grep -q via-udp /var/log/remotes/packer-logs/buildcheck.log",
      "grep -q via-tcp /var/log/remotes/packer-logs/buildcheck.log",
      # A sender can't write outside /var/log/remotes with a crafted host or tag.
      "python3 -c \"import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); [s.sendto(m, ('127.0.0.1', 514)) for m in (b'<13>Oct 10 00:00:00 .. ../../../tmp/zz-pathcheck: x', b'<13>Oct 10 00:00:00 ../../tmp/zz-pathcheck-host prog: y')]\"",
      "sleep 2",
      "test $(grep -rl zz-pathcheck /var/log/remotes | wc -l) -ge 1",
      "if find / -xdev -name '*zz-pathcheck*' -not -path '/var/log/remotes/*' | grep -q .; then echo 'remote message escaped /var/log/remotes' >&2; exit 1; fi",
      # The real config parses, and a forced rotation (without delaycompress,
      # which would leave the first rotation uncompressed) writes valid zstd.
      "test -x /usr/lib/rsyslog/rsyslog-rotate",
      "if logrotate -d /etc/logrotate.d/remote-logs 2>&1 | grep -i '^error'; then exit 1; fi",
      "sed '/delaycompress/d' /etc/logrotate.d/remote-logs > /tmp/remote-logs",
      "logrotate -f -s /tmp/logrotate.state /tmp/remote-logs",
      "zstd -tq /var/log/remotes/packer-logs/buildcheck.log-*.zst",
      # rsyslog reopened its files after the rotation's HUP.
      "logger -n 127.0.0.1 -P 514 --udp -t buildcheck after-rotate",
      "sleep 2",
      "grep -q after-rotate /var/log/remotes/packer-logs/buildcheck.log",
      # tmpfiles expires by mtime (atime stays fresh here) and skips _archive.
      "mkdir -p /var/log/remotes/oldhost /var/log/remotes/_archive",
      "touch /var/log/remotes/oldhost/old.log-20200101.zst /var/log/remotes/_archive/history.tar.zst",
      "touch -m -d '200 days ago' /var/log/remotes/oldhost/old.log-20200101.zst /var/log/remotes/_archive/history.tar.zst",
      "systemd-tmpfiles --clean /etc/tmpfiles.d/remote-logs.conf",
      "test ! -e /var/log/remotes/oldhost/old.log-20200101.zst",
      "test -e /var/log/remotes/_archive/history.tar.zst",
      "test -e /var/log/remotes/packer-logs/buildcheck.log",
      "systemctl stop rsyslog",
      "rm -rf /var/log/remotes/* /tmp/remote-logs /tmp/logrotate.state",
    ], local.image_cleanup)
  }
}
