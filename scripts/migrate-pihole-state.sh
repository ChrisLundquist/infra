#!/bin/bash
# Copy the state we curate by hand from one Pi-hole LXD instance to another:
#   gravity.db  - allow/deny entries, groups and clients. Blocklists come from
#                 the new image (files/etc/pihole/adlists.list), and the repo's
#                 files/etc/pihole/allowlist.list is re-applied on top.
#   pihole.toml - local DNS records and CNAMEs; everything else keeps the new
#                 image's config.
#
# usage: scripts/migrate-pihole-state.sh <old-instance> <new-instance>
# Instance names can carry a remote, e.g. nuc:pihole. Nothing is written to
# the old instance; files are only pulled from it.
#
# Teleporter would be simpler, but importing a backup from an older FTL fails
# on gravity schema changes, after it has already overwritten the config.

set -euo pipefail

old=$1
new=$2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# gravity.db uses a rollback journal, so a copy taken while no write
# transaction is open (no -journal file before or after) is consistent.
gravity_quiet() {
  ! lxc exec "$old" -- test -e /etc/pihole/gravity.db-journal < /dev/null
}

echo "Copying allow/deny entries, groups and clients from $old to $new"
gravity_quiet || { echo "gravity.db on $old is mid-write; try again" >&2; exit 1; }
lxc file pull "$old/etc/pihole/gravity.db" "$tmp/gravity-old.db"
gravity_quiet || { echo "gravity.db on $old changed during the copy; try again" >&2; exit 1; }
lxc file push --uid=0 --gid=0 --mode=0600 "$tmp/gravity-old.db" "$new/root/gravity-old.db"
lxc exec "$new" -- sh -c 'test "$(pihole-FTL sqlite3 /root/gravity-old.db "PRAGMA integrity_check")" = ok' < /dev/null

# These tables have kept the same columns since v5, so copy them with explicit
# column lists. The link tables are replaced after the inserts because the
# schema's triggers add every new row to the default group; orphaned links in
# the old database are skipped. Imported groups that had blocklists get all of
# the image's blocklists. .bail makes any error abort before COMMIT.
lxc exec "$new" -- pihole-FTL sqlite3 /etc/pihole/gravity.db <<'EOF'
.bail on
ATTACH '/root/gravity-old.db' AS old;
BEGIN;
DELETE FROM domainlist;
DELETE FROM client;
DELETE FROM "group" WHERE id != 0;
INSERT INTO "group" (id, enabled, name, date_added, date_modified, description)
  SELECT id, enabled, name, date_added, date_modified, description FROM old."group" WHERE id != 0;
INSERT INTO domainlist (id, type, domain, enabled, date_added, date_modified, comment)
  SELECT id, type, domain, enabled, date_added, date_modified, comment FROM old.domainlist;
INSERT INTO client (id, ip, date_added, date_modified, comment)
  SELECT id, ip, date_added, date_modified, comment FROM old.client;
DELETE FROM domainlist_by_group;
INSERT INTO domainlist_by_group (domainlist_id, group_id)
  SELECT domainlist_id, group_id FROM old.domainlist_by_group
  WHERE domainlist_id IN (SELECT id FROM domainlist) AND group_id IN (SELECT id FROM "group");
DELETE FROM client_by_group;
INSERT INTO client_by_group (client_id, group_id)
  SELECT client_id, group_id FROM old.client_by_group
  WHERE client_id IN (SELECT id FROM client) AND group_id IN (SELECT id FROM "group");
INSERT OR IGNORE INTO adlist_by_group (adlist_id, group_id)
  SELECT adlist.id, g.group_id FROM adlist,
    (SELECT DISTINCT group_id FROM old.adlist_by_group WHERE group_id IN (SELECT id FROM "group")) AS g;
COMMIT;
EOF
lxc exec "$new" -- rm /root/gravity-old.db < /dev/null

echo "Re-applying the repo allowlist"
lxc exec "$new" -- sh -c "grep -vE '^\s*(#|$)' /etc/pihole/allowlist.list | xargs -r pihole allow -q --comment 'repo allowlist.list'" < /dev/null

echo "Copying local DNS records and CNAMEs"
lxc file pull "$old/etc/pihole/pihole.toml" "$tmp/pihole.toml"
python3 -I - "$tmp/pihole.toml" > "$tmp/settings" <<'EOF'
import json, sys, tomllib

with open(sys.argv[1], "rb") as f:
    dns = tomllib.load(f).get("dns", {})

print("dns.hosts", json.dumps(dns.get("hosts", [])))
print("dns.cnameRecords", json.dumps(dns.get("cnameRecords", [])))
EOF
# lxc exec would otherwise eat the rest of the settings file from stdin.
while read -r key value; do
  lxc exec "$new" -- pihole-FTL --config "$key" "$value" > /dev/null < /dev/null
done < "$tmp/settings"

lxc exec "$new" -- pihole reloadlists > /dev/null < /dev/null
lxc exec "$new" -- pihole reloaddns > /dev/null < /dev/null
