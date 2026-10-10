# infra

Packer templates for the home lab's LXD container images.

| Image | Built from | What it is |
|---|---|---|
| `resolute-base` | `ubuntu:resolute` (26.04 LTS) | avahi, squid-deb-proxy-client (finds apt-cacher-ng over mDNS), remote rsyslog to `logs.local`, unattended-upgrades |
| `apt-cacher-ng` | `resolute-base` | apt proxy on :3142, advertised over mDNS |
| `distcc` | `resolute-base` | distccd on :3632 for the LAN, with the release's gcc/g++ (workers must match the clients' compiler) |
| `pihole` | `resolute-base` | Pi-hole v6 with unbound on 127.0.0.1:5335 as its only upstream, no admin password |

## Building

We build with our fork of the LXD plugin
([ChrisLundquist/packer-plugin-lxd](https://github.com/ChrisLundquist/packer-plugin-lxd)),
so install it from source instead of running `packer init` (which would pull
upstream's release). The fork's `main` has the fixes these templates need on
LXD 6: `-force` rebuilds move the image alias to the new image (the previous
image stays, unaliased, for rollback), and uploaded files land root-owned with
their source mode.

```bash
cd ~/code/packer-plugin-lxd && git checkout main && git pull clundquist main && go build -o packer-plugin-lxd . && packer plugins install --path ./packer-plugin-lxd github.com/hashicorp/lxd
```

Then build the base image first, since the others start from it:

```bash
make base
```

```bash
make pihole apt-cacher-ng distcc
```

Building only publishes images to the local LXD image store; it doesn't touch
running containers. The pihole build fails if the result can't resolve, block,
or validate DNSSEC.

Variables (pass with `-var name=value` or `PKR_VAR_name`):

- `ubuntu_release`: codename for the base image (default `resolute`).
- `dns_upstream_mode`: `recursive` (default) has unbound resolve from the root
  servers itself, so no single provider sees every query. `dot` forwards
  everything to Quad9 over DNS-over-TLS instead, which hides queries from the
  ISP but trusts Quad9 with all of them.

## Pi-hole blocklists

`files/etc/pihole/adlists.list` holds four maintained lists: HaGeZi Multi Pro
(ads, tracking, telemetry), HaGeZi Threat Intelligence Feeds (malware,
phishing, C2), OISD big and the AdGuard DNS filter. A
`pihole-gravity.timer` rebuilds gravity daily, since the threat-intel feeds go
stale within hours. `files/etc/pihole/allowlist.list` holds exact domains the
household needs that these lists block; the build applies it, and so does
`scripts/migrate-pihole-state.sh` after copying entries from an old Pi-hole.

## Deploying

See [DEPLOY.md](DEPLOY.md). Deploys are blue/green: bring the new container up
next to the old one, verify it, then move the address over.
