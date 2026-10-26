#!/bin/bash
# Deletes EVERYTHING created by this project (stops all billing)
RG=${RG:-rg-hrms-lab}
az group delete -n $RG --yes --no-wait && echo "Deleting $RG ... check later: az group exists -n $RG"
