# Deploying new images without downtime

Every swap is blue/green. Start the new container next to the old one, check it
works, then move the address or traffic over. The old container stays stopped
(not deleted) until you're happy, so rolling back is just
`lxc stop <new> && lxc start <old>`.

Commands assume the LXD host is the current `lxc` remote. Prefix instance
names with a remote (e.g. `deon:`) for other hosts. `lxc rename` only works on
a stopped instance, which is why swaps stop the new container briefly. A
renamed container picks up its new name as hostname (and mDNS name) on start.

## State as of 2026-10-10 (worth re-checking first)

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
    metal): Ubuntu 22.04, Pi-hole core 6.1.4 / FTL 6.2.3, created 2022-12.
    Leave it alone until there's a go-ahead (section 2). Its upstream is
    cloudflared 2022.1.2 on 127.0.0.1#5300, installed from a standalone .deb
    with `--no-autoupdate` and no apt source, so it won't update by itself.
    Don't upgrade it by hand: `proxy-dns` was removed in cloudflared 2026.2.0.
    Its netplan has `dhcp4: true` plus the static .253, so it also holds
    .145.
- deon (LXD 6.7, `dir` storage pool, 44 of 469 GiB used) holds `pihole-basic`,
  `ts-exit-1` (Tailscale exit node) and `logs` (static .146, the `logs.local`
  syslog target), plus stopped 18.04 containers `distcc-5`, `ums` and `vpn`.
  `ts-exit-1` has no template here yet.
  - `logs` runs this repo's 26.04 `logs` image since 2026-10-10, with its logs
    on the custom volume `logs-remotes`. The 18.04 container it replaced is
    stopped as `logs-bionic`; its logs back to 2019 are in
    `/var/log/remotes/_archive/logs-bionic-remotes-20261010.tar.zst`.
- nuc2's `apt-cacher-ng` and `distcc-2` run this repo's 26.04 images since
  2026-10-10; the old ones are stopped as `apt-cacher-ng-focal` (with its 29G
  cache) and `distcc-bionic`. distcc workers must run the same compiler as
  their clients, so the new one serves 26.04 clients (gcc 15).
- The `default` storage pool is a 91 GiB loop file with about 23 GiB free.
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

## 1. Pi-hole on nuc2 (`.254`, and the same for `.26`)

Done on 2026-10-10 for both addresses; this is the procedure for the next
upgrade.

1. Launch the new image, which gets a temporary DHCP address, and refresh its
   blocklists. The threat-intel feeds baked in at build time go stale within
   hours; after this, a daily timer keeps them fresh.

   ```bash
   lxc launch pihole pihole-next
   ```

   ```bash
   lxc exec pihole-next -- pihole -g
   ```

2. Copy the hand-curated state from the working Pi-hole (`deon:pihole-basic`
   at `.253`): allow/deny entries,
   groups, clients, local DNS records and CNAMEs. Blocklists come from the
   image (`files/etc/pihole/adlists.list`), the repo's
   `files/etc/pihole/allowlist.list` is re-applied on top, and there's
   deliberately no admin password. Nothing is written to the source.

   ```bash
   scripts/migrate-pihole-state.sh deon:pihole-basic pihole-next
   ```

   Don't use teleporter for this. Importing a backup from an older FTL fails
   partway on gravity schema changes (tested 6.3 → 6.7) after it has already
   overwritten the config.

3. Check it with the DHCP address from `lxc list pihole-next`:

   ```bash
   dig @<pihole-next-ip> example.com +short && dig @<pihole-next-ip> pagead2.googlesyndication.com +short && dig @<pihole-next-ip> dnssec-failed.org | grep status
   ```

   Expect real addresses, then `0.0.0.0`, then `SERVFAIL`.

4. Give it the static address. The file only takes effect on the next boot,
   so write it while the old container still holds `.254`:

   ```bash
   lxc exec pihole-next -- sh -c 'printf "network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: false\n      addresses: [192.168.0.254/24]\n      routes: [{to: default, via: 192.168.0.1}]\n      nameservers: {addresses: [127.0.0.1]}\n" > /etc/netplan/60-static.yaml && chmod 600 /etc/netplan/60-static.yaml'
   ```

5. Swap. While a Pi-hole restarts, clients use the other resolver:

   ```bash
   lxc stop pihole && lxc rename pihole pihole-focal
   ```

   ```bash
   lxc stop pihole-next && lxc rename pihole-next pihole && lxc start pihole
   ```

   Then repeat the `dig` checks against `192.168.0.254`.

6. Optionally add `.254` to the router's DHCP DNS servers alongside `.26`
   and `.253`.

## 2. Pi-hole: roll `.253` onto the new image

Only with a go-ahead for deon. Clients already have `.26` as a second
working resolver. Then do the same on deon, keeping the name
`pihole-basic` so the two Pi-holes keep distinct mDNS names. Copy the image
over first:

```bash
lxc image copy pihole deon: --alias pihole
```

```bash
lxc launch deon:pihole deon:pihole-basic-next && lxc exec deon:pihole-basic-next -- pihole -g
```

```bash
scripts/migrate-pihole-state.sh deon:pihole-basic deon:pihole-basic-next
```

Check it as in step 1.3, then write the static address with
`192.168.0.253/24` as in step 1.4 (into `deon:pihole-basic-next`), and swap:

```bash
lxc stop deon:pihole-basic && lxc rename deon:pihole-basic deon:pihole-basic-old
```

```bash
lxc stop deon:pihole-basic-next && lxc rename deon:pihole-basic-next deon:pihole-basic && lxc start deon:pihole-basic
```

While `.253` restarts, `.254` answers; clients that try `.253` first may wait
one resolver timeout during the few seconds of the swap. Upgrades after this
follow the same pattern, one Pi-hole at a time.

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

On deon (its logs are in the `_archive` tarball):

```bash
lxc delete logs-bionic
```
