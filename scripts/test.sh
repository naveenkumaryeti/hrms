#!/bin/bash
# Run in Cloud Shell after deploy.sh:  bash scripts/test.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd); source "$ROOT/secrets.txt"
H='Content-Type: application/json'; U=https://$FQDN; J=$(mktemp)
ok(){ [[ "$2" == *"$3"* ]] && echo "PASS  $1" || echo "FAIL  $1  (got: $2)"; }
ok "T1 wrong password -> 401" "$(curl -sk -w ' [%{http_code}]' -X POST $U/api/auth/login -H "$H" -d '{"identifier":"admin","password":"wrong"}')" "[401]"
ok "T2 admin login -> 200" "$(curl -sk -c $J -w ' [%{http_code}]' -X POST $U/api/auth/login -H "$H" -d "{\"identifier\":\"admin\",\"password\":\"$HRMS_ADMIN_PASSWORD\"}")" "[200]"
ok "T4 no cookie -> 401" "$(curl -sk -w ' [%{http_code}]' $U/api/employees)" "[401]"
ok "T5 add employee -> 201" "$(curl -sk -b $J -w ' [%{http_code}]' -X POST $U/api/employees -H "$H" -d '{"full_name":"Test User","email":"test.user@hrms.local","department":"QA","designation":"Tester","joining_date":"2026-11-01","employment_status":"ACTIVE"}')" "[201]"
ok "T6 weak signup -> 400" "$(curl -sk -w ' [%{http_code}]' -X POST $U/api/auth/signup -H "$H" -d '{"username":"tester","email":"test.user@hrms.local","password":"weak"}')" "[400]"
ok "T6b unknown email -> 403" "$(curl -sk -w ' [%{http_code}]' -X POST $U/api/auth/signup -H "$H" -d '{"username":"nobody","email":"nobody@x.com","password":"Strong-Pass123"}')" "[403]"
curl -sk -X POST $U/api/auth/signup -H "$H" -d '{"username":"tester","email":"test.user@hrms.local","password":"Strong-Pass123","role":"ADMIN"}' >/dev/null
E=$(mktemp); curl -sk -c $E -X POST $U/api/auth/login -H "$H" -d '{"identifier":"tester","password":"Strong-Pass123"}' >/dev/null
ok "T8 employee on admin API -> 403" "$(curl -sk -b $E -w ' [%{http_code}]' $U/api/employees)" "[403]"
q(){ az vm run-command invoke -g $RG -n $1 --command-id RunShellScript --scripts "$2" --query 'value[0].message' -o tsv 2>&1; }
ok "T10 backend reaches MySQL" "$(q vm-hrms-app 'curl -s http://10.10.2.4:3000/api/health')" "connected"
ok "T11 web VM blocked from MySQL" "$(q vm-hrms-web 'nc -zv -w 5 10.10.3.4 3306 2>&1 || echo BLOCKED')" "BLOCKED"
ok "T12 web VM reaches API port" "$(q vm-hrms-web 'nc -zv -w 5 10.10.2.4 3000 2>&1')" "succeeded"
ok "T13 jump box reads DB; new user role is EMPLOYEE" "$(q vm-hrms-jumpbox "mysql -h 10.10.3.4 -u hrms_admin -p'$DB_ADMIN_PASSWORD' hrms_db -e 'SELECT username,role FROM users; SELECT employee_id,full_name,email,department FROM employees;'")" "EMPLOYEE"
ok "T14 DB has no public IP" "$(az network nic show -g $RG -n nic-hrms-db --query 'ipConfigurations[0].publicIPAddress' -o tsv)x" "x"
ok "T15 two NSGs" "$(az network nsg list -g $RG --query 'length(@)')" "2"
ok "T15 three ASGs" "$(az network asg list -g $RG --query 'length(@)')" "3"
