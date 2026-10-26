---
title: "Azure Three-Tier HRMS - Deployment Guide"
subtitle: "Complete workable code + step-by-step instructions"
---

# 1. What you get

| Folder | Contents |
|---|---|
| `backend/` | Node.js + Express API (`server.js`), admin seeder (`seed-admin.js`), `package.json`, `.env.example`, systemd service |
| `frontend/` | Login, Signup, Admin Login, Admin Dashboard, Employee Dashboard (HTML/CSS/JS) and the Nginx config |
| `database/` | `schema.sql` (tables `roles`, `employees`, `users`) |
| `scripts/` | `deploy.sh` (builds all of Azure and installs everything), `test.sh`, `cleanup.sh`, and one `setup-*.sh` per VM |

**What gets built:** 1 VNet, 5 subnets, 3 ASGs, exactly 2 NSGs, 4 Ubuntu VMs (web, app, database, jump box), Azure Bastion and a NAT Gateway. The employee form on the website really writes to MySQL, and you verify it from the jump box.

# 2. Architecture in one picture

```
Internet --HTTPS 443--> [vm-hrms-web 10.10.1.4  Nginx]  asg-hrms-web   NSG-1
                              | TCP 3000
                        [vm-hrms-app 10.10.2.4  Node.js] asg-hrms-app  NSG-2
                              | TCP 3306
                        [vm-hrms-db  10.10.3.4  MySQL ]  asg-hrms-db   NSG-2 (no public IP)
                              ^ TCP 3306 (read-only admin check)
 Admin --Azure Portal--> Bastion --SSH--> [vm-hrms-jumpbox 10.10.5.4]
```

| Subnet | CIDR | Holds | NSG |
|---|---|---|---|
| snet-hrms-web | 10.10.1.0/24 | Web VM | nsg-hrms-web-app |
| snet-hrms-app | 10.10.2.0/24 | App VM | nsg-hrms-app-db |
| snet-hrms-db | 10.10.3.0/24 | DB VM | nsg-hrms-app-db |
| AzureBastionSubnet | 10.10.4.0/26 | Bastion | none |
| snet-hrms-mgmt | 10.10.5.0/24 | Jump box | none |

**NSG rules (created automatically by `deploy.sh`)**

| NSG | Name | Dir | Pri | Source | Destination | Port | Action |
|---|---|---|---|---|---|---|---|
| web-app | Allow-HTTPS-Internet | In | 100 | Internet | asg-hrms-web | 443 | Allow |
| web-app | Allow-HTTP-Redirect | In | 110 | Internet | asg-hrms-web | 80 | Allow |
| web-app | Allow-SSH-From-Bastion | In | 120 | 10.10.4.0/26 | asg-hrms-web | 22 | Allow |
| web-app | Deny-All-Inbound | In | 4000 | * | * | * | Deny |
| web-app | Allow-API-To-App | Out | 100 | asg-hrms-web | asg-hrms-app | 3000 | Allow |
| app-db | Allow-API-From-Web | In | 100 | asg-hrms-web | asg-hrms-app | 3000 | Allow |
| app-db | Allow-MySQL-From-App | In | 110 | asg-hrms-app | asg-hrms-db | 3306 | Allow |
| app-db | Allow-MySQL-From-Jumpbox | In | 120 | 10.10.5.4/32 | asg-hrms-db | 3306 | Allow |
| app-db | Allow-SSH-Bastion-App | In | 130 | 10.10.4.0/26 | asg-hrms-app | 22 | Allow |
| app-db | Allow-SSH-Bastion-DB | In | 140 | 10.10.4.0/26 | asg-hrms-db | 22 | Allow |
| app-db | Deny-All-Inbound | In | 4000 | * | * | * | Deny |
| app-db | Allow-MySQL-To-DB | Out | 100 | asg-hrms-app | asg-hrms-db | 3306 | Allow |

Why the Deny rule matters: Azure's default `AllowVnetInBound` (priority 65000) lets every VM talk to every VM. Our Deny at 4000 is checked first, so the web VM cannot reach MySQL. `nsg-hrms-app-db` is attached to two subnets (app and db) to stay at exactly two NSGs.

# 3. Prerequisites

> **Free-tier note:** free accounts usually have a **4 vCPU per region** limit and some VM sizes are blocked. `deploy.sh` reads your quota and automatically picks 1-vCPU sizes (4 VMs = 4 vCPUs) in South India. Make sure Cloud Shell is in **Bash** (type `bash` if the prompt starts with `PS`).

1. An Azure subscription (Contributor role) with room for about 6 vCPUs in Central India.
2. A browser. No local tools are needed - we use **Azure Cloud Shell**.
3. Estimated cost: a few US dollars if you finish the same day and run the cleanup.

# 4. Deploy (about 25 minutes)

1. Sign in at portal.azure.com. Click the `>_` icon (top bar) and choose **Bash**.
2. Click **Manage files -> Upload** and upload `hrms-azure-project.zip`.
3. Run:
```bash
unzip hrms-azure-project.zip && cd hrms
bash scripts/deploy.sh
cd ~/hrms
az group exists -n rg-hrms-lab      # must print false
export LOC=southindia
export SZ=Standard_DC1s_v3
bash scripts/deploy.sh

```
4. Wait for `DONE`. The script prints your website address and admin password, and saves all passwords in `secrets.txt`.
5. Optional settings before running: `export LOC=eastus` (another region), `export SZ=Standard_DC1s_v3` (force a VM size), `export RG=my-rg-name`, `export DNS=mycustomlabel` (must be globally unique, lowercase).

**What `deploy.sh` does, step by step**

| Phase | Action | Verify yourself |
|---|---|---|
| 1 | Resource group `rg-hrms-lab` | `az group show -n rg-hrms-lab -o table` |
| 2 | VNet `vnet-hrms-prod` + 5 subnets | `az network vnet subnet list -g rg-hrms-lab --vnet-name vnet-hrms-prod -o table` |
| 3 | 3 ASGs | `az network asg list -g rg-hrms-lab -o table` |
| 4 | 2 NSGs, 12 rules, attached to subnets; NAT Gateway for private VMs | `az network nsg rule list -g rg-hrms-lab --nsg-name nsg-hrms-app-db -o table` |
| 5 | 4 NICs with fixed private IPs and ASG badges, 4 VMs | `az vm list -g rg-hrms-lab -d -o table` |
| 6 | Public IP for the website; Azure Bastion (starts in background, ~10 min) | Portal -> Bastions |
| 7-12 | Uses Azure *Run Command* to run `setup-db.sh`, `setup-app.sh`, `setup-web.sh`, `setup-jump.sh` on each VM | output printed in Cloud Shell |

The VMs have no public SSH. Software is installed through Azure Run Command, and later admin access is through Bastion.

# 5. Use the application (demo script)

1. Open `https://<FQDN>` (printed at the end). Accept the browser warning (self-signed certificate - normal for a lab).
2. Click **Admin login**. Username `admin`, password from the script output (or `secrets.txt`).
3. In **Add Employee** enter: Priya Sharma, priya@hrms.local, Engineering, DevOps Engineer, a date, ACTIVE -> **Save**. A green message shows `Employee saved in database (ID 1001)`.
4. She appears in the table. Type `Eng` in the search box to filter. Click **Edit** to update any field.
5. Logout. Click **New employee? Sign up**: username `priya`, email `priya@hrms.local`, password `Welcome-2026ab` (10+ characters, upper, lower, digit). Signup works only because HR (the admin) registered that email.
6. Log in as `priya`: the Employee page shows only her profile. Opening `/admin.html` sends her back to login, and `/api/employees` returns 403.

# 6. Verify the data in MySQL from the jump box

**Fastest (no Bastion):** the database is private, so running `mysql` directly in Cloud Shell fails by design (*Can't connect to 10.10.3.4*). Run the query *through* the jump box instead:
```bash
source ~/hrms/secrets.txt
az vm run-command invoke -g $RG -n vm-hrms-jumpbox --command-id RunShellScript --scripts "mysql -h 10.10.3.4 -u hrms_admin -p'$DB_ADMIN_PASSWORD' hrms_db -e 'SHOW TABLES; SELECT employee_id, full_name, email, department FROM employees; SELECT user_id, username, email, role FROM users;'" --query 'value[0].message' -o tsv
```
Show passwords with `cat ~/hrms/secrets.txt`.

**Interactive (Bastion):**

1. Portal -> Virtual machines -> `vm-hrms-jumpbox` -> **Connect -> Connect via Bastion** (wait until Bastion shows *Succeeded*).
2. Username `azureuser`, password `VM_PASSWORD` from `secrets.txt`.
3. Run:
```bash
mysql -h 10.10.3.4 -u hrms_admin -p hrms_db
```
Enter `DB_ADMIN_PASSWORD` from `secrets.txt`, then:
```sql
SHOW TABLES;
SELECT employee_id, full_name, email, department FROM employees;
SELECT user_id, username, email, role FROM users;
INSERT INTO roles VALUES ('X','test');
```
The last command must fail (`ERROR 1142`): this account is read-only. The row with ID 1001 proves the website wrote to the database.

# 7. Automated tests

```bash
bash scripts/test.sh
```
Prints PASS or FAIL for: wrong login (401), admin login, no-cookie access (401), add employee (201), signup validation (400/403), employee blocked from admin API (403), backend reaches MySQL, **web VM blocked from MySQL**, web VM reaches API port, jump box reads the database, DB has no public IP, exactly 2 NSGs and 3 ASGs. Each run adds a test employee `Test User` and a user `tester`; a second run reports duplicates for some steps - that is expected.

Extra manual checks: SQL injection - type `' OR '1'='1` as username; you get *Invalid username or password*. Public signup cannot create admins: the API ignores any `role` field and always creates `EMPLOYEE`.

# 8. API reference

| Method | Endpoint | Who | Purpose |
|---|---|---|---|
| GET | /api/health | anyone | API + database check |
| POST | /api/auth/signup | HR-registered email | Create EMPLOYEE account |
| POST | /api/auth/login | anyone | Log in (secure HTTP-only cookie, 30 min) |
| POST | /api/auth/logout | logged in | Clear cookie |
| GET | /api/auth/me | logged in | Current role |
| GET | /api/employees/me | logged in | Own profile |
| GET | /api/employees?search=x | ADMIN | Searchable list |
| POST | /api/employees | ADMIN | Add employee (parameterized INSERT) |
| PUT | /api/employees/:id | ADMIN | Update employee |

Add-employee request: `{"full_name":"Priya Sharma","email":"priya@hrms.local","department":"Engineering","designation":"DevOps Engineer","joining_date":"2026-11-01","employment_status":"ACTIVE"}` -> `201 {"success":true,"message":"Employee saved in database (ID 1001)","employee_id":1001}`.

# 9. Database design

- `employees` holds every HR fact about a person (primary key `employee_id`, starts at 1001, unique email).
- `users` holds only login data (unique `username`/`email`, bcrypt `password_hash`, `role`) and links to its employee with `employee_id` (foreign key, unique) - personal data is never stored twice.
- `roles` lists valid roles; `users.role` must match it (foreign key).
- DB accounts: `hrms_app` (only from 10.10.2.4; SELECT/INSERT on users, SELECT/INSERT/UPDATE on employees, SELECT on roles - no DELETE, no schema changes) and `hrms_admin` (only from 10.10.5.4; SELECT only).

# 10. Security built in

| Topic | Implementation |
|---|---|
| HTTPS | Nginx TLS 1.2+, HTTP redirects to HTTPS (self-signed in lab) |
| Passwords | bcrypt cost 12; strength rules enforced on the server |
| Sessions | JWT in a Secure, HttpOnly, SameSite=Strict cookie, 30-minute expiry; login rate-limited |
| Authorization | Role checked in the backend on every protected route |
| SQL injection | Only parameterized queries |
| Secrets | `.env` file (permission 600), random JWT secret, no credentials in code |
| Network | No public IP on app, DB or jump box; NSG deny-by-default; MySQL listens only on 10.10.3.4 |
| Backups (lab) | `sudo mysqldump hrms_db > ~/hrms_backup.sql` on the DB VM |
| Patching | `sudo apt update && sudo apt upgrade -y` |

**Lab vs production:** production adds trusted certificates, Application Gateway with WAF, Azure Key Vault with managed identities, Azure Database for MySQL Flexible Server (private access or Private Endpoint; no VM, ASG or SSH needed; TLS required), redundant VMs behind a load balancer, Bastion Standard with MFA, automated backups, Log Analytics monitoring and infrastructure-as-code.

# 11. Monitoring

Portal -> each VM -> **Monitoring -> Metrics** (Percentage CPU, Network In/Out). Resource group -> **Activity log** shows who changed what. Logs via Bastion: `sudo journalctl -u hrms-api -n 50` (app VM), `/var/log/nginx/access.log` (web VM), `/var/log/mysql/error.log` (DB VM). **Network Watcher -> IP flow verify** (10.10.1.4 to 10.10.3.4, port 3306) shows `Deny-All-Inbound` blocking the web VM.

# 12. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `SkuNotAvailable` or quota error | Region capacity or vCPU quota | The script now picks an available size automatically. If none: `bash scripts/cleanup.sh`, `export LOC=southindia` (or `eastus`), rerun. To force a size: `export SZ=Standard_D2s_v5`. Four VMs need 8 vCPUs of quota |
| `DNS name already taken` | Label not unique | `export DNS=mylabel$RANDOM` and rerun |
| Script stops midway | Network or capacity hiccup | Run `bash scripts/cleanup.sh`, wait for deletion, rerun `deploy.sh` |
| Website times out | VM still installing, or NSG issue | Wait 2 minutes; check rule `Allow-HTTPS-Internet` |
| 404 Not Found on the home page | Old Nginx config | Fixed in this version; on an old deployment edit `/etc/nginx/sites-available/hrms` so the line reads `try_files $uri $uri/ =404;` and run `sudo systemctl reload nginx` |
| `export` or `for` not recognized | Cloud Shell is in PowerShell | Type `bash` first |
| `mysql` from Cloud Shell cannot connect | DB is private (correct) | Use the jump box (Section 6) |
| 502 Bad Gateway | API not running | Rerun the app step: see section 13 |
| `Access denied for user` | Password or source IP mismatch | Use the passwords in `secrets.txt`; account hosts are fixed to 10.10.2.4 and 10.10.5.4 |
| Signup says email not registered | Admin has not added that employee | Add employee first |
| `apt` hangs on private VMs | NAT Gateway missing | `az network vnet subnet list` should show a NAT gateway on app, db, mgmt |
| Bastion button greyed out | Bastion still deploying | Wait ~10 minutes |

# 13. Re-running one component

Each VM script is safe to rerun. Example (from the `hrms` folder in Cloud Shell, after `source secrets.txt`):
```bash
B64=$(tar czf - backend frontend database scripts | base64 -w0)
printf "mkdir -p /opt/hrms-src && echo '%s' | base64 -d | tar xz -C /opt/hrms-src && export X=1 && bash /opt/hrms-src/scripts/setup-web.sh" "$B64" > /tmp/w.sh
az vm run-command invoke -g $RG -n vm-hrms-web --command-id RunShellScript --scripts @/tmp/w.sh --query 'value[0].message' -o tsv
```
For the app VM also add `export APPPW='<APP_DB_PASSWORD>' ADMINPW='<HRMS_ADMIN_PASSWORD>'` before `bash`.

# 14. Cleanup (important)

Bastion, NAT Gateway and public IPs bill every hour.
```bash
bash scripts/cleanup.sh
az group exists -n rg-hrms-lab     # prints false when finished
```
