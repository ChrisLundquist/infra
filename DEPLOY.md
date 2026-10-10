# Deploying new images without downtime

Every swap is blue/green. Start the new container next to the old one, check it
works, then move the address or traffic over. The old container stays stopped
(not deleted) until you're happy, so rolling back is just
`lxc stop <new> && lxc start <old>`.

Commands assume the LXD host is the current `lxc` remote. Prefix instance
names with a remote (e.g. `deon:`) for other hosts. `lxc rename` only works on
a stopped instance, which is why swaps stop the new container briefly. A
renamed container picks up its new name as hostname (and mDNS name) on start.

## State as of 2026-10-09 (worth re-checking first)

- LAN clients get DNS servers `192.168.0.253` and `192.168.0.26` from DHCP.
  - `.253` is `pihole-basic` on deon (`deon.local`, 192.168.0.71, bare
    metal): Ubuntu 22.04, Pi-hole core 6.1.4 / FTL 6.2.3, created 2022-12.
    It's the only working resolver on the LAN. Its upstream is cloudflared
    on 127.0.0.1#5300, whose `proxy-dns` was removed in cloudflared 2026.2.0,
    so an update to that package would take the LAN's DNS down. Its netplan
    has `dhcp4: true` plus the static .253, so it also holds .145.
  - `.26` isn't any instance on deon or nuc2 and doesn't answer ping or ARP.
    It's a stale DHCP entry; take it out of the router's DNS list now so
    clients stop timing out on it.
- deon also runs `logs` (.146, the `logs.local` syslog target, Ubuntu
  18.04), `ts-exit-1` (Tailscale exit node), and stopped 18.04 containers
  `distcc-5`, `ums` and `vpn`. None of these have templates here yet.
- The `pihole` container on this host (`.254`, plus `.3` from DHCP) runs
  Ubuntu 20.04. Its `dns.upstreams` is empty, so it answers `REFUSED` to
  everything. It also runs a 2022 cloudflared and a stray ntpd. No client
  depends on it, which makes it the safe one to replace first.
- `apt-cacher-ng` on this host is also Ubuntu 20.04, with a 29G cache.
  `apt-cacher-ng-next` (26.04) is already running next to it from an earlier
  build of the image; both answer over mDNS.
- `distcc-2` on this host is Ubuntu 18.04 with gcc 7/8. distcc needs workers
  to run the same compiler as the client, so it can't help 26.04 clients
  (gcc 15), and its log shows no recent jobs.
- The `default` storage pool is a 91 GiB loop file with about 23 GiB free.
  Every `make` rebuild keeps the previous image (unaliased) for rollback, so
  prune old ones now and then (`lxc image list`, then `lxc image delete`).

## 0. Let nuc2 reach deon

The Pi-hole state to migrate lives on `deon:pihole-basic`, and step 2 needs
the image on deon. nuc2's lxc client isn't trusted there yet. On deon:

```bash
lxc config trust add --name nuc2
```

Then on nuc2, with the token it prints:

```bash
lxc remote add deon 192.168.0.71 --token <token>
```

## 1. Pi-hole: replace the broken `.254` first

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

5. Swap. Nothing uses `.254` today, so this doesn't affect clients:

   ```bash
   lxc stop pihole && lxc rename pihole pihole-focal
   ```

   ```bash
   lxc stop pihole-next && lxc rename pihole-next pihole && lxc start pihole
   ```

   Then repeat the `dig` checks against `192.168.0.254`.

6. On the router, change the DHCP DNS servers to `.254, .253` (dropping the
   dead `.26`). Clients pick this up as their leases renew. Both servers work,
   so nobody loses DNS in the meantime.

## 2. Pi-hole: roll `.253` onto the new image

Wait until clients have renewed their leases (or a lease length has passed)
so everyone has `.254`. Then do the same on deon, keeping the name
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

Clients find the proxy over mDNS (`_apt_proxy._tcp`), and
squid-deb-proxy-client falls back to going direct when it finds none. That
means two proxies can run side by side.

`apt-cacher-ng-next` is currently running from an older build of the image, so
replace it first:

```bash
lxc delete -f apt-cacher-ng-next
```

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

## Clean up

Once the new containers have run cleanly for a while:

```bash
lxc delete pihole-focal apt-cacher-ng-focal distcc-bionic
```
