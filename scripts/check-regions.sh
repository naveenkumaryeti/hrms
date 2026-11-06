#!/usr/bin/env bash
#
# Check Azure regions for available Public IP quota.
#
# Usage:
#   ./scripts/check-regions.sh
#   REQUIRED_IPS=5 ./scripts/check-regions.sh
#
# This checks quota only. It does NOT guarantee VM capacity or SKU availability.

set -u

REQUIRED_IPS="${REQUIRED_IPS:-4}"

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: Azure CLI (az) was not found. Run this script in Azure Cloud Shell or install Azure CLI."
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 was not found."
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "ERROR: You are not logged in to Azure. Run: az login"
  exit 1
fi

echo "Checking recommended physical Azure regions..."
echo "Required available Public IP addresses: ${REQUIRED_IPS}"
echo "Subscription: $(az account show --query name -o tsv 2>/dev/null)"
echo "------------------------------------------------------------"

REGIONS="$(
  az account list-locations \
    --query "[?metadata.regionType=='Physical' && metadata.regionCategory=='Recommended'].name" \
    --output tsv 2>/dev/null
)"

if [[ -z "${REGIONS}" ]]; then
  echo "ERROR: Azure CLI returned no recommended physical regions."
  echo "Check your Azure account permissions and try: az account list-locations -o table"
  exit 1
fi

FOUND=0
CHECKED=0
SKIPPED=0

while IFS= read -r REGION; do
  [[ -z "${REGION}" ]] && continue
  CHECKED=$((CHECKED + 1))

  USAGES="$(az network list-usages --location "${REGION}" --output json 2>/dev/null)"
  if [[ -z "${USAGES}" ]]; then
    echo "SKIPPED: ${REGION} (quota API did not return data)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  RESULT="$(
    printf '%s' "${USAGES}" | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("INVALID")
    raise SystemExit(0)

for item in data:
    name = item.get("name", {}).get("value", "")
    if name in ("PublicIPAddresses", "Public IP Addresses"):
        try:
            limit = int(item.get("limit", 0))
            used = int(item.get("currentValue", 0))
            print(f"{limit} {used} {limit - used}")
        except (TypeError, ValueError):
            print("INVALID")
        break
else:
    print("NOT_FOUND")
'
  )"

  if [[ "${RESULT}" == "INVALID" || "${RESULT}" == "NOT_FOUND" || -z "${RESULT}" ]]; then
    echo "SKIPPED: ${REGION} (Public IP quota value unavailable)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  read -r LIMIT USED AVAILABLE <<< "${RESULT}"

  if (( AVAILABLE >= REQUIRED_IPS )); then
    echo "MATCH: ${REGION} | Limit: ${LIMIT} | Used: ${USED} | Available: ${AVAILABLE}"
    FOUND=$((FOUND + 1))
  else
    echo "Below requirement: ${REGION} | Limit: ${LIMIT} | Used: ${USED} | Available: ${AVAILABLE}"
  fi
done <<< "${REGIONS}"

echo "------------------------------------------------------------"
echo "Regions checked: ${CHECKED}"
echo "Matching regions: ${FOUND}"
echo "Skipped regions: ${SKIPPED}"
echo
echo "NEXT STEP: For each matching region, verify your VM SKU:"
echo "  az vm list-skus --location <REGION> --size Standard_DC1s_v3 --all -o table"
echo "Also check regional and VM-family vCPU quotas with:"
echo "  az vm list-usage --location <REGION> -o table"
echo
echo "Note: Quota availability does not guarantee actual VM capacity or deployment success."

