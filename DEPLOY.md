# Deploying new images without downtime

Every swap is blue/green. Start the new container next to the old one, check it
works, then move the address or traffic over. The old container stays stopped
(not deleted) until you're happy, so rolling back is just
`lxc stop <new> && lxc start <old>`.

Commands assume the LXD host is the current `lxc` remote. Prefix instance
names with a remote (e.g. `deon:`) for other hosts. `lxc rename` only works on
a stopped instance, which is why swaps stop the new container briefly. A
renamed container picks up its new name as hostname (and mDNS name) on start.

## State as of 2026-11-08 (worth re-checking first)

- On 2026-11-08 all three Pi-holes moved to Pi-hole core 6.5, web 6.6.1 and
  FTL 6.8 with `scripts/roll-pihole.sh` (sections 1 and 2), keeping their
  lists, MACs and query history. The FTL 6.7.1 containers are stopped as
  `pihole-ftl671` and `pihole2-ftl671` on nuc2. deon's copy was deleted in
  its clean-up the same day.
- LAN clients get DNS servers `192.168.0.253` and `192.168.0.26` from DHCP.
  Both work now.
  - `.26` is `pihole2` on nuc2 (26.04, this repo's `pihole` image), deployed
    2026-10-10 on an address nothing else held.
  - `.254` is `pihole` on nuc2 (same image), replacing a broken 20.04
    container that answered `REFUSED` to everything (kept stopped as
    `pihole-focal`). It isn't in the router's DHCP DNS list yet. Both nuc2
    Pi-holes got their allow/deny entries from that old container, plus
    `files/etc/pihole/allowlist.list`.
  - `.253` is `pihole-basic` on deon (`deon.local`, 192.168.0.71, bare
    metal), rolled onto this repo's `pihole` image on 2026-10-10 (section 2)
    with its allow/deny entries and its full query history. The old Ubuntu
    22.04 / FTL 6.2.3 container with the cloudflared upstream has since been
    deleted.
  - All three Pi-holes have no admin password (by choice). Since FTL 6.8
    (GHSA-322h-f873-hp54), a Pi-hole without a password refuses API requests
    a browser sends on behalf of another website, and requests under host
    names it doesn't know (DNS rebinding). It accepts its IP addresses,
    `pi.hole`, `webserver.domain` and its hostname (alone, `.lan` or
    `.local`). The image also blanks the CORS headers
    (`webserver.advancedOpts` in `files/etc/pihole/pihole.toml`) as a second
    layer.
- deon (LXD 6.10, `dir` storage pool, 22 of 469 GiB used) runs only
  `pihole-basic`, `ts-exit-1` (Tailscale exit node) and `logs` (static .146,
  the `logs.local` syslog target). `ts-exit-1` has no template here yet.
  - Its clean-up was done on 2026-11-08. All stopped containers were deleted:
    `distcc-5`, `logs-bionic`, `logs-old`, `pihole-basic-old`,
    `pihole-basic-ftl671`, `ums` and `vpn`. The unused images went too.
  - `vpn` and `ums` were exported first to `/var/backups/lxd-exports/`
    (root-only, zstd).
  - `logs` runs this repo's 26.04 `logs` image since 2026-10-10, with its logs
    on the custom volume `logs-remotes`. The logs of the 18.04 container it
    replaced, going back to 2019, are in
    `/var/log/remotes/_archive/logs-bionic-remotes-20261010.tar.zst`.
- nuc2's `apt-cacher-ng` and `distcc-2` run this repo's 26.04 images since
  2026-10-10; the old ones are stopped as `apt-cacher-ng-focal` (with its 29G
  cache) and `distcc-bionic`. distcc workers must run the same compiler as
  their clients, so the new one serves 26.04 clients (gcc 15).
- Throwaway containers on `br0` each take a router DHCP lease (12h). On
  2026-10-10 a day of builds and tests used up the pool, and new LAN devices
  got no address until leases expired. Builds and tests now run on the
  `build` profile's NAT network (README), and deploys give new containers no
  NIC (`lxc config device add <name> eth0 none`) until their static address
  takes over.
- nuc2's `default` storage pool is a 91 GiB loop file with about 27 GiB free
  (2026-11-08).
  Every `make` rebuild keeps the previous image (unaliased) for rollback, so
  prune old ones now and then (`lxc image list`, then `lxc image delete`).

## 0. Let nuc2 reach deon

The Pi-hole state to migrate lives on `deon:pihole-basic`, and step 2 needs
the image on deon. nuc2's lxc client isn't trusted there yet, and deon
doesn't know nuc2 as a remote. Either run the deon steps from deon itself
(after building or copying the images there), or trust nuc2. On deon:

```bash
lxc config trust add --name nuc2
```

Then on nuc2, with the token it prints:

```bash
lxc remote add deon 192.168.0.71 --token <token>
```

## 1. Pi-holes on nuc2 (`.254`, then `.26`)

Last done on 2026-11-08 (FTL 6.7.1 to 6.8), with about 8 seconds without each
address while the other Pi-holes answered. `scripts/roll-pihole.sh` does the
whole swap, in two steps:

- `prepare <name> <image> <ip>` starts `<name>-next` on the `build` profile,
  which gives it internet through NAT without taking a LAN DHCP lease. It
  refreshes the blocklists and copies from the running container:
  - allow/deny entries, groups, clients and local DNS records, with
    `scripts/migrate-pihole-state.sh`;
  - the query history, as a `.backup` copy of `pihole-FTL.db`.

  It then writes the static address, checks DNS, DNSSEC and the API, and
  stops the new container. The running Pi-hole keeps serving throughout.
- `swap <name> <ip>` refuses to run unless the other Pi-holes answer. It
  stops the old container and keeps it as `<name>-ftl<version>`, moves its
  MAC so LAN ARP caches stay valid, switches the new container to the
  `default` profile and starts it under the old name. If `<ip>` doesn't
  answer within 90 seconds, it puts the old container back.

Roll `.254` first: the router doesn't hand it out, so it's the canary. Then
`.26`, then `.253` (section 2).

```bash
scripts/roll-pihole.sh prepare pihole pihole 192.168.0.254
```

```bash
scripts/roll-pihole.sh swap pihole 192.168.0.254
```

Then do the same with `pihole2` and `192.168.0.26`, and check it from another
machine:

```bash
dig @192.168.0.26 example.com +short && dig @192.168.0.26 pagead2.googlesyndication.com +short && dig @192.168.0.26 dnssec-failed.org | grep status
```

Expect real addresses, then `0.0.0.0`, then `SERVFAIL`.

To roll back by hand, reverse the swap:
1. Stop the new container, unset its `volatile.eth0.hwaddr` and rename it
   away.
2. Rename `<name>-ftl<version>` back, give it the MAC and start it.

Don't use teleporter to copy state. Importing a backup from an older FTL fails
partway on gravity schema changes (tested 6.3 to 6.7), after it has already
overwritten the config.

## 2. Pi-hole on deon (`.253`)

Last done on 2026-11-08, with about 9 seconds without `.253` while `.26`
answered. deon has no GitHub access and isn't an LXD remote of nuc2, so copy
the image and both scripts over SSH. deon has no `dig`; the script falls back
to a Python DNS query for its checks. On nuc2:

```bash
lxc image export pihole /tmp/pihole && ssh deon.local 'mkdir -p /tmp/roll' && scp /tmp/pihole.tar.gz scripts/roll-pihole.sh scripts/migrate-pihole-state.sh deon.local:/tmp/roll/ && rm /tmp/pihole.tar.gz
```

deon still has an older image under the `pihole` alias, so import this one
under a dated alias, then prepare and swap as in section 1:

```bash
ssh deon.local 'cd /tmp/roll && lxc image import pihole.tar.gz --alias pihole-<YYYYMMDD> && rm pihole.tar.gz'
```

```bash
ssh deon.local 'cd /tmp/roll && ./roll-pihole.sh prepare pihole-basic pihole-<YYYYMMDD> 192.168.0.253'
```

```bash
ssh deon.local 'cd /tmp/roll && ./roll-pihole.sh swap pihole-basic 192.168.0.253 && rm -rf /tmp/roll'
```

## 3. apt-cacher-ng

Done on 2026-10-10; this is the procedure for the next upgrade.

Clients find the proxy over mDNS (`_apt_proxy._tcp`), and
squid-deb-proxy-client falls back to going direct when it finds none. That
means two proxies can run side by side.

```bash
lxc launch apt-cacher-ng apt-cacher-ng-next
```

Don't copy the old cache across: at 29G it would fill the storage pool for
every container on this host, and most of it is focal packages. The new cache
fills on demand.

Check that `curl -s http://<next-ip>:3142/acng-report.html` loads, then retire
the old one:

```bash
lxc stop apt-cacher-ng && lxc rename apt-cacher-ng apt-cacher-ng-focal
```

```bash
lxc stop apt-cacher-ng-next && lxc rename apt-cacher-ng-next apt-cacher-ng && lxc start apt-cacher-ng
```

For the few seconds in between, clients find no proxy and fetch directly.

## 4. distcc

Done on 2026-10-10; this is the procedure for the next upgrade.

distcc clients fall back to compiling locally when a worker is unreachable,
so a short gap is harmless.

```bash
lxc launch distcc distcc-next
```

Check that a client with the same compiler (gcc 15 on 26.04) can use it with
fallback disabled, from any machine in `ALLOWEDNETS`:

```bash
echo 'int main(void){return 0;}' > /tmp/h.c && DISTCC_HOSTS=<distcc-next-ip> DISTCC_FALLBACK=0 distcc gcc -c /tmp/h.c -o /tmp/h.o
```

```bash
lxc stop distcc-2 && lxc rename distcc-2 distcc-bionic
```

```bash
lxc stop distcc-next && lxc rename distcc-next distcc-2 && lxc start distcc-2
```

The new container gets a new DHCP address, so update any client's
`DISTCC_HOSTS` or `/etc/distcc/hosts` that names the old IP.

## 5. logs (deon)

Done on 2026-10-10; this is the procedure for the next upgrade. The image
builds on deon itself (`make logs`, after `make base`).

Clients send to `logs.local` over UDP, and rsyslog resolves that name only
when it starts, so the new container has to take over the old one's address
(`192.168.0.146`) or every client keeps sending to the old IP until its
rsyslog restarts. The new container also takes the old MAC, so ARP caches on
the LAN stay valid. LXD refuses to start an instance whose MAC another
instance (even a stopped one) still has, so the old container gives its MAC
up; it gets a new one if it's ever started again.

The logs live on the custom volume `logs-remotes`, which moves from the old
container to the new one. Nothing needs copying.

1. Create the new container with the volume detached (the old one is still
   writing to it) and check it receives. It may not get a DHCP address,
   which doesn't matter, so test over loopback:

   ```bash
   lxc launch logs logs-next
   ```

   ```bash
   lxc exec logs-next -- sh -c 'logger -n 127.0.0.1 -P 514 --udp -t deploycheck hi && sleep 2 && cat /var/log/remotes/logs-next/deploycheck.log && rm -r /var/log/remotes/logs-next'
   ```

2. Give it the static address. It takes effect on the next start:

   ```bash
   lxc exec logs-next -- sh -c 'printf "network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: false\n      addresses: [192.168.0.146/24]\n      routes: [{to: default, via: 192.168.0.1}]\n      nameservers: {addresses: [192.168.0.253, 192.168.0.26]}\n" > /etc/netplan/60-static.yaml && chmod 600 /etc/netplan/60-static.yaml'
   ```

3. Swap. Logs sent during the few seconds in between are lost (UDP):

   ```bash
   lxc stop logs && lxc rename logs logs-old && lxc config device remove logs-old remotes
   ```

   ```bash
   MAC=$(lxc config get logs-old volatile.eth0.hwaddr) && lxc config unset logs-old volatile.eth0.hwaddr && lxc stop logs-next && lxc config set logs-next volatile.eth0.hwaddr "$MAC" && lxc config device add logs-next remotes disk pool=default source=logs-remotes path=/var/log/remotes && lxc rename logs-next logs && lxc start logs
   ```

4. Check from a client, then on the server:

   ```bash
   logger -t deploycheck "hello from $(hostname)"
   ```

   ```bash
   lxc exec logs -- sh -c 'tail -n1 /var/log/remotes/*/deploycheck.log'
   ```

To roll back, stop `logs`, move the volume and the MAC back to `logs-old` the
same way, and start it.

The first deploy (from the 18.04 container, which kept its logs in its own
rootfs) created the volume with `lxc storage volume create default
logs-remotes`, and archived the old logs into it once `logs-bionic` was
stopped:

```bash
sudo tar -C /var/snap/lxd/common/lxd/storage-pools/default/containers/logs-bionic/rootfs/var/log -cf - remotes | zstd -T0 -12 --long=27 | lxc exec logs -- sh -c 'cat > /var/log/remotes/_archive/logs-bionic-remotes-20261010.tar.zst'
```

Read it with `zstd -dc --long=27 <file> | tar -tvf -` (or `-xf -`).
`_archive` is exempt from the 90-day expiry.

## Clean up

Once the new containers have run cleanly for a while:

```bash
lxc delete pihole-focal apt-cacher-ng-focal distcc-bionic
```

The FTL 6.7.1 Pi-holes from the 2026-11-08 roll, on nuc2:

```bash
lxc delete pihole-ftl671 pihole2-ftl671
```

deon's clean-up is done (2026-11-08); see the state section above.
