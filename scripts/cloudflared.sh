#!/bin/bash

set -xe
# wget -O cloudflared.deb https://bin.equinox.io/c/VdrWdbjqyF/cloudflared-stable-linux-amd64.deb
wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/download/2022.1.2/cloudflared-linux-amd64.deb
apt install -y ./cloudflared.deb

mkdir /etc/cloudflared/
cat << EOF > /etc/cloudflared/config.yml
proxy-dns: true
proxy-dns-upstream:
 - https://1.1.1.1/dns-query
 - https://1.0.0.1/dns-query
proxy-dns-port: 5300
EOF

cloudflared service install --legacy
service cloudflared start
