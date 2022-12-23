#!/bin/bash

cat /etc/pihole/adlists.list | xargs -n1 -I{} sudo sqlite3 /etc/pihole/gravity.db "INSERT INTO adlist (address, enabled, comment) VALUES ('{}', 1, 'comment');"
