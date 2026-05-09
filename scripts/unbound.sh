#!/bin/bash

set -xe

DEBIAN_FRONTEND=noninteractive apt update
DEBIAN_FRONTEND=noninteractive apt install -y unbound ca-certificates

systemctl enable unbound.service
