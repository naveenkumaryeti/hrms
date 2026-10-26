#!/bin/bash
# Runs ON vm-hrms-jumpbox (as root)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y mysql-client
mysql --version
