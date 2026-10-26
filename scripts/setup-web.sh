#!/bin/bash
# Runs ON vm-hrms-web (as root)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y nginx openssl
mkdir -p /etc/nginx/ssl /var/www/hrms
[ -f /etc/nginx/ssl/hrms.crt ] || openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/nginx/ssl/hrms.key -out /etc/nginx/ssl/hrms.crt -subj '/CN=hrms-lab'
cp /opt/hrms-src/frontend/*.html /opt/hrms-src/frontend/*.css /opt/hrms-src/frontend/*.js /var/www/hrms/
cp /opt/hrms-src/frontend/nginx-hrms.conf /etc/nginx/sites-available/hrms
ln -sf /etc/nginx/sites-available/hrms /etc/nginx/sites-enabled/hrms
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
curl -skI https://localhost | head -1
