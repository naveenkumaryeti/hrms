#!/bin/bash
# Runs ON vm-hrms-app (as root). Needs env: APPPW ADMINPW
set -euo pipefail
: "${APPPW:?}" "${ADMINPW:?}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y netcat-openbsd curl
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
id hrms >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin hrms
D=/opt/hrms-api; mkdir -p $D
cp /opt/hrms-src/backend/server.js /opt/hrms-src/backend/seed-admin.js /opt/hrms-src/backend/package.json $D/
cd $D && npm install --omit=dev
cat > .env <<EOF
PORT=3000
HOST=10.10.2.4
DB_HOST=10.10.3.4
DB_USER=hrms_app
DB_PASSWORD=$APPPW
DB_NAME=hrms_db
JWT_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 .env; chown -R hrms:hrms $D
nc -zv -w 5 10.10.3.4 3306
node seed-admin.js admin admin@hrms.local "$ADMINPW" || echo 'admin already exists'
cp /opt/hrms-src/backend/hrms-api.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now hrms-api
sleep 4; curl -s http://10.10.2.4:3000/api/health
