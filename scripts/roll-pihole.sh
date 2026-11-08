#!/bin/bash
# Replace a running Pi-hole container with one from a newer image, keeping its
# address, MAC, lists and query history. Run it on the LXD host that holds the
# container (for deon, copy this and migrate-pihole-state.sh over first).
#
#   scripts/roll-pihole.sh prepare <name> <image> <ip>
#       Starts <name>-next from <image> on the `build` NAT profile (no LAN
#       DHCP lease), refreshes its lists, copies the lists and query history
#       from <name>, writes its static address, checks it, and stops it.
#       <name> keeps serving throughout.
#   scripts/roll-pihole.sh swap <name> <ip>
#       Refuses unless every other resolver in RESOLVERS answers. Then stops
#       <name>, keeps it as <name>-ftl<version>, moves its MAC to <name>-next
#       and starts that as <name>. If <ip> doesn't answer within 90 seconds it
#       puts the old container back. Clients use the other resolver meanwhile.
#
# RESOLVERS defaults to the LAN's Pi-holes.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=
RESOLVERS=${RESOLVERS:-"192.168.0.253 192.168.0.26 192.168.0.254"}

log() { echo "$(date +%T) $*"; }
die() { log "ERROR: $*"; exit 1; }

answers() { # <server> -- does it resolve a public name?
  if command -v dig > /dev/null; then
    dig +time=2 +tries=1 +short @"$1" example.com 2>/dev/null | grep -qE '^[0-9.]+$'
    return
  fi
  # Hosts without dnsutils (deon): one A query for example.com, NOERROR with an answer.
  python3 -I - "$1" <<'EOF'
import random, socket, struct, sys
qid = random.randrange(65536)
query = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + b"\x07example\x03com\x00" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
try:
    s.sendto(query, (sys.argv[1], 53))
    reply = s.recv(4096)
except OSError:
    sys.exit(1)
rid, flags, _, ancount = struct.unpack(">HHHH", reply[:8])
sys.exit(0 if rid == qid and flags & 0xF == 0 and ancount > 0 else 1)
EOF
}

in_ct() { lxc exec "$1" -- sh -c "$2" < /dev/null; }

wait_ftl() { # <instance>
  for _ in $(seq 1 60); do
    in_ct "$1" 'systemctl is-active -q pihole-FTL && dig +time=2 +tries=1 +short @127.0.0.1 pagead2.googlesyndication.com | grep -q .' && return 0
    sleep 2
  done
  return 1
}

prepare() {
  local name=$1 image=$2 ip=$3 next=$1-next
  lxc info "$name" > /dev/null 2>&1 || die "$name doesn't exist"
  lxc info "$next" > /dev/null 2>&1 && die "$next already exists; delete it first"
  tmp=$(mktemp -d); trap '[ -n "$tmp" ] && rm -rf "$tmp"' EXIT

  log "starting $next from $image on the build network"
  lxc init "$image" "$next" --profile build && lxc start "$next" || die "couldn't start $next"
  wait_ftl "$next" || die "FTL didn't come up in $next"

  log "refreshing blocklists"
  in_ct "$next" 'pihole -g > /dev/null' || die "gravity update failed in $next"

  log "copying lists, groups, clients and local DNS from $name"
  "$here/migrate-pihole-state.sh" "$name" "$next" || die "state migration failed"

  log "copying query history from $name"
  in_ct "$name" 'pihole-FTL sqlite3 /etc/pihole/pihole-FTL.db ".backup /tmp/roll-ftl.db"' || die "history backup failed"
  lxc file pull "$name/tmp/roll-ftl.db" "$tmp/ftl.db"; local rc=$?
  in_ct "$name" 'rm -f /tmp/roll-ftl.db'
  [ $rc = 0 ] || die "couldn't pull the history copy"
  in_ct "$next" 'systemctl stop pihole-FTL && rm -f /etc/pihole/pihole-FTL.db /etc/pihole/pihole-FTL.db-*' || die "couldn't stop FTL in $next"
  lxc file push --uid=0 --gid=0 --mode=0640 "$tmp/ftl.db" "$next/etc/pihole/pihole-FTL.db" || die "couldn't push the history"
  in_ct "$next" 'chown pihole:pihole /etc/pihole/pihole-FTL.db && systemctl start pihole-FTL' || die "FTL didn't restart in $next"
  wait_ftl "$next" || die "FTL didn't come back in $next"

  log "writing the static address $ip (applies on the next start)"
  in_ct "$next" "printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: false\n      addresses: [$ip/24]\n      routes: [{to: default, via: 192.168.0.1}]\n      nameservers: {addresses: [127.0.0.1]}\n' > /etc/netplan/60-static.yaml && chmod 600 /etc/netplan/60-static.yaml && netplan generate" || die "netplan failed"

  log "checking $next"
  local q='pihole-FTL sqlite3 -readonly /etc/pihole/pihole-FTL.db "select count(*) from query_storage"'
  local d='pihole-FTL sqlite3 -readonly /etc/pihole/gravity.db "select count(*) from domainlist"'
  local old_q new_q old_d new_d
  old_q=$(in_ct "$name" "$q"); new_q=$(in_ct "$next" "$q")
  old_d=$(in_ct "$name" "$d"); new_d=$(in_ct "$next" "$d")
  in_ct "$next" '
    set -e
    pihole -v | head -3
    dig +short +time=5 @127.0.0.1 example.com | grep -q .
    test "$(dig +short +time=5 @127.0.0.1 pagead2.googlesyndication.com)" = 0.0.0.0
    dig +time=5 @127.0.0.1 dnssec-failed.org | grep -q "status: SERVFAIL"
    dig +dnssec +time=5 @127.0.0.1 isc.org | grep -q "flags:.* ad"
    curl -sf -H "Host: pi.hole" http://127.0.0.1/api/auth | grep -q "\"valid\":true"
  ' || die "$next failed its DNS/API checks"
  log "list entries: $name $old_d, $next $new_d; queries: $name $old_q, $next $new_q"
  [ "$old_d" = "$new_d" ] || die "list entries don't match"
  [ "$new_q" -ge $((old_q * 9 / 10)) ] || die "query history didn't copy"

  log "stopping $next until the swap"
  lxc stop "$next" || die "couldn't stop $next"
  log "prepared $next; run: $0 swap $name $ip"
}

swap() {
  local name=$1 ip=$2 next=$1-next mac ver old o
  lxc info "$next" | grep -q '^Status: STOPPED' || die "$next isn't prepared (or is running)"
  for o in $RESOLVERS; do
    [ "$o" = "$ip" ] && continue
    answers "$o" || die "the other resolver $o isn't answering; not taking $ip down"
  done

  ver=$(in_ct "$name" 'pihole-FTL --version' | tr -cd '0-9')
  old=$name-ftl$ver
  lxc info "$old" > /dev/null 2>&1 && die "$old already exists"
  mac=$(lxc config get "$name" volatile.eth0.hwaddr)
  [ -n "$mac" ] || die "no MAC on $name"

  log "stopping $name ($ip is down from here) and keeping it as $old"
  lxc stop "$name" || die "couldn't stop $name"
  lxc rename "$name" "$old" && lxc config unset "$old" volatile.eth0.hwaddr || { lxc start "$name"; die "rename failed; restarted $name"; }

  if lxc profile assign "$next" default && lxc config set "$next" volatile.eth0.hwaddr "$mac" &&
     lxc rename "$next" "$name" && lxc start "$name"; then
    for _ in $(seq 1 45); do
      if answers "$ip"; then
        log "new $name answers on $ip"
        in_ct "$name" 'pihole updatechecker > /dev/null 2>&1; pihole -v | head -3'
        return 0
      fi
      sleep 2
    done
    log "new $name didn't answer on $ip within 90s"
  else
    log "couldn't start the new $name"
  fi

  log "rolling back to $old"
  lxc stop -f "$name" 2>/dev/null
  if lxc info "$name" > /dev/null 2>&1; then
    lxc config unset "$name" volatile.eth0.hwaddr
    lxc rename "$name" "$next-failed"
  fi
  lxc rename "$old" "$name" && lxc config set "$name" volatile.eth0.hwaddr "$mac" && lxc start "$name"
  for _ in $(seq 1 30); do answers "$ip" && { log "old $name answers on $ip again"; exit 1; }; sleep 2; done
  die "old $name doesn't answer either; check it now"
}

case "${1:-}" in
  prepare) [ $# = 4 ] || die "usage: $0 prepare <name> <image> <ip>"; prepare "$2" "$3" "$4" ;;
  swap)    [ $# = 3 ] || die "usage: $0 swap <name> <ip>"; swap "$2" "$3" ;;
  *)       die "usage: $0 prepare <name> <image> <ip> | swap <name> <ip>" ;;
esac
