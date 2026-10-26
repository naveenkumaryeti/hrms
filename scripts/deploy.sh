#!/bin/bash
# Run in Azure Cloud Shell (Bash) from the project root:  bash scripts/deploy.sh
set -euo pipefail
az config set extension.use_dynamic_install=yes_without_prompt extension.dynamic_install_allow_preview=true >/dev/null 2>&1 || true
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RG=${RG:-rg-hrms-lab}; VNET=vnet-hrms-prod; VMUSER=azureuser
DNS=${DNS:-hrms$RANDOM$RANDOM}
LOC=${LOC:-southindia}
if [ -z "${SZ:-}" ]; then
  LIM=$(az vm list-usage -l $LOC --query "[?name.value=='cores'].limit|[0]" -o tsv 2>/dev/null || echo 4)
  if [ "${LIM:-4}" -ge 8 ]; then CANDS="Standard_B2s_v2 Standard_B2s Standard_B2als_v2 Standard_D2s_v5 Standard_D2s_v3 Standard_D2as_v5"
  else CANDS="Standard_B1ms Standard_B1s Standard_A1_v2 Standard_DC1s_v3 Standard_DC1ds_v3 Standard_F1als_v7"; fi
  echo "== vCPU quota in $LOC is $LIM; looking for an available VM size"
  for c in $CANDS; do
    n=$(az vm list-skus -l $LOC --size $c --resource-type virtualMachines --query "[?length(restrictions)==\`0\`]|length(@)" -o tsv 2>/dev/null || echo 0)
    if [ "${n:-0}" -gt 0 ]; then SZ=$c; break; fi
  done
  [ -n "${SZ:-}" ] || { echo "No suitable VM size in $LOC. Try another region (export LOC=eastus) or upgrade to Pay-as-you-go"; exit 1; }
fi
echo "Using VM size: $SZ in $LOC"

pw(){ echo "$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 14)Aa1-"; }
VMPASS=$(pw); APPPW=$(pw); DBAPW=$(pw); ADMINPW=$(pw)
echo "== 1 Resource group"; az group create -n $RG -l $LOC -o none
echo "== 2 VNet and subnets"
az network vnet create -g $RG -n $VNET -l $LOC --address-prefixes 10.10.0.0/16 --subnet-name snet-hrms-web --subnet-prefixes 10.10.1.0/24 -o none
az network vnet subnet create -g $RG --vnet-name $VNET -n snet-hrms-app --address-prefixes 10.10.2.0/24 -o none
az network vnet subnet create -g $RG --vnet-name $VNET -n snet-hrms-db --address-prefixes 10.10.3.0/24 -o none
az network vnet subnet create -g $RG --vnet-name $VNET -n AzureBastionSubnet --address-prefixes 10.10.4.0/26 -o none
az network vnet subnet create -g $RG --vnet-name $VNET -n snet-hrms-mgmt --address-prefixes 10.10.5.0/24 -o none
echo "== 3 ASGs"; for a in web app db; do az network asg create -g $RG -n asg-hrms-$a -l $LOC -o none; done
echo "== 4 NSGs and rules"
az network nsg create -g $RG -n nsg-hrms-web-app -l $LOC -o none
az network nsg create -g $RG -n nsg-hrms-app-db -l $LOC -o none
rule(){ # nsg name priority direction access source destination port
  local A=() PROTO=Tcp
  if [[ $6 == asg-* ]]; then A+=(--source-asgs "$6"); else A+=(--source-address-prefixes "$6"); fi
  if [[ $7 == asg-* ]]; then A+=(--destination-asgs "$7"); else A+=(--destination-address-prefixes "$7"); fi
  [[ $8 == '*' ]] && PROTO='*'
  az network nsg rule create -g $RG --nsg-name $1 -n $2 --priority $3 --direction $4 --access $5 --protocol "$PROTO" --destination-port-ranges "$8" "${A[@]}" -o none
}
W=nsg-hrms-web-app; D=nsg-hrms-app-db
rule $W Allow-HTTPS-Internet 100 Inbound Allow Internet asg-hrms-web 443
rule $W Allow-HTTP-Redirect 110 Inbound Allow Internet asg-hrms-web 80
rule $W Allow-SSH-From-Bastion 120 Inbound Allow 10.10.4.0/26 asg-hrms-web 22
rule $W Deny-All-Inbound 4000 Inbound Deny '*' '*' '*'
rule $W Allow-API-To-App 100 Outbound Allow asg-hrms-web asg-hrms-app 3000
rule $D Allow-API-From-Web 100 Inbound Allow asg-hrms-web asg-hrms-app 3000
rule $D Allow-MySQL-From-App 110 Inbound Allow asg-hrms-app asg-hrms-db 3306
rule $D Allow-MySQL-From-Jumpbox 120 Inbound Allow 10.10.5.4/32 asg-hrms-db 3306
rule $D Allow-SSH-Bastion-App 130 Inbound Allow 10.10.4.0/26 asg-hrms-app 22
rule $D Allow-SSH-Bastion-DB 140 Inbound Allow 10.10.4.0/26 asg-hrms-db 22
rule $D Deny-All-Inbound 4000 Inbound Deny '*' '*' '*'
rule $D Allow-MySQL-To-DB 100 Outbound Allow asg-hrms-app asg-hrms-db 3306
az network vnet subnet update -g $RG --vnet-name $VNET -n snet-hrms-web --network-security-group $W -o none
az network vnet subnet update -g $RG --vnet-name $VNET -n snet-hrms-app --network-security-group $D -o none
az network vnet subnet update -g $RG --vnet-name $VNET -n snet-hrms-db --network-security-group $D -o none
echo "== NAT gateway (outbound internet for private VMs)"
az network public-ip create -g $RG -n pip-hrms-nat --sku Standard --allocation-method Static -l $LOC -o none
az network nat gateway create -g $RG -n natgw-hrms -l $LOC --public-ip-addresses pip-hrms-nat --idle-timeout 10 -o none
for s in app db mgmt; do az network vnet subnet update -g $RG --vnet-name $VNET -n snet-hrms-$s --nat-gateway natgw-hrms -o none; done
echo "== 5 NICs and VMs"
az network public-ip create -g $RG -n pip-hrms-web --sku Standard --allocation-method Static --dns-name $DNS -l $LOC -o none
az network nic create -g $RG -n nic-hrms-web --vnet-name $VNET --subnet snet-hrms-web --private-ip-address 10.10.1.4 --application-security-groups asg-hrms-web --public-ip-address pip-hrms-web -o none
az network nic create -g $RG -n nic-hrms-app --vnet-name $VNET --subnet snet-hrms-app --private-ip-address 10.10.2.4 --application-security-groups asg-hrms-app -o none
az network nic create -g $RG -n nic-hrms-db --vnet-name $VNET --subnet snet-hrms-db --private-ip-address 10.10.3.4 --application-security-groups asg-hrms-db -o none
az network nic create -g $RG -n nic-hrms-jump --vnet-name $VNET --subnet snet-hrms-mgmt --private-ip-address 10.10.5.4 -o none
mkvm(){ az vm create -g $RG -n $1 --nics $2 --size $3 --image Ubuntu2204 --admin-username $VMUSER --authentication-type password --admin-password "$VMPASS" --no-wait -o none; }
mkvm vm-hrms-web nic-hrms-web $SZ; mkvm vm-hrms-app nic-hrms-app $SZ
mkvm vm-hrms-db nic-hrms-db $SZ; mkvm vm-hrms-jumpbox nic-hrms-jump $SZ
az vm wait -g $RG --created --ids $(az vm list -g $RG --query '[].id' -o tsv) -o none
echo "== 6 Bastion (takes ~10 min, runs in background)"
az network public-ip create -g $RG -n pip-hrms-bastion --sku Standard --allocation-method Static -l $LOC -o none
az network bastion create -g $RG -n bas-hrms -l $LOC --vnet-name $VNET --public-ip-address pip-hrms-bastion --sku Basic --no-wait
echo "== 7-12 Install software on each VM (Azure Run Command)"
B64=$(tar czf - -C "$ROOT" backend frontend database scripts | base64 -w0)
run(){ # vm script envpairs
  cat > /tmp/w.sh <<EOF
set -e
mkdir -p /opt/hrms-src
echo '$B64' | base64 -d | tar xz -C /opt/hrms-src
export $3
bash /opt/hrms-src/scripts/$2
EOF
  echo "-- $1: $2"; az vm run-command invoke -g $RG -n $1 --command-id RunShellScript --scripts @/tmp/w.sh --query 'value[0].message' -o tsv
}
run vm-hrms-db setup-db.sh "APPPW='$APPPW' DBAPW='$DBAPW'"
run vm-hrms-app setup-app.sh "APPPW='$APPPW' ADMINPW='$ADMINPW'"
run vm-hrms-web setup-web.sh "X=1"
run vm-hrms-jumpbox setup-jump.sh "X=1"
FQDN=$(az network public-ip show -g $RG -n pip-hrms-web --query dnsSettings.fqdn -o tsv)
cat > "$ROOT/secrets.txt" <<EOF
RG=$RG
FQDN=$FQDN
VM_USER=$VMUSER
VM_PASSWORD=$VMPASS
APP_DB_PASSWORD=$APPPW
DB_ADMIN_USER=hrms_admin
DB_ADMIN_PASSWORD=$DBAPW
HRMS_ADMIN_USER=admin
HRMS_ADMIN_PASSWORD=$ADMINPW
EOF
chmod 600 "$ROOT/secrets.txt"
echo; echo "DONE. Open https://$FQDN  (accept the certificate warning)"
echo "Admin login: admin / $ADMINPW   (all secrets saved in secrets.txt - keep it private)"
