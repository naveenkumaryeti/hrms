#!/bin/bash
# Runs ON vm-hrms-db (as root). Needs env: APPPW DBAPW
set -euo pipefail
: "${APPPW:?}" "${DBAPW:?}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y mysql-server
sed -i 's/^bind-address.*/bind-address = 10.10.3.4/' /etc/mysql/mysql.conf.d/mysqld.cnf
systemctl restart mysql
mysql < /opt/hrms-src/database/schema.sql
mysql <<SQL
CREATE USER IF NOT EXISTS 'hrms_app'@'10.10.2.4' IDENTIFIED BY '$APPPW';
ALTER USER 'hrms_app'@'10.10.2.4' IDENTIFIED BY '$APPPW';
GRANT SELECT,INSERT ON hrms_db.users TO 'hrms_app'@'10.10.2.4';
GRANT SELECT,INSERT,UPDATE ON hrms_db.employees TO 'hrms_app'@'10.10.2.4';
GRANT SELECT ON hrms_db.roles TO 'hrms_app'@'10.10.2.4';
CREATE USER IF NOT EXISTS 'hrms_admin'@'10.10.5.4' IDENTIFIED BY '$DBAPW';
ALTER USER 'hrms_admin'@'10.10.5.4' IDENTIFIED BY '$DBAPW';
GRANT SELECT ON hrms_db.* TO 'hrms_admin'@'10.10.5.4';
FLUSH PRIVILEGES;
SQL
ss -tlnp | grep 3306
mysql -e "SHOW TABLES FROM hrms_db;"
