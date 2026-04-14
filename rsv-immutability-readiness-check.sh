#!/bin/bash
# ===================================================================================================
# RSV Immutability Readiness Check
# Produces 3 CSVs + summary table to assess readiness for vault locking.
#
# Output files (timestamped):
#   1) no-expiry-rps-YYYYMMDD-HHMMSS.csv       — Recovery points with no expiry
#   2) no-policy-items-YYYYMMDD-HHMMSS.csv     — Backup items with no policy
#   3) no-expiry-no-policy-YYYYMMDD-HHMMSS.csv — Items in BOTH (the real risk)
#
# Usage:
#   ./rsv-immutability-readiness-check.sh                     # default (10 parallel, skip last 48h)
#   SKIP_RECENT_HOURS=0 ./rsv-immutability-readiness-check.sh # include all RPs
#   PARALLEL=5 ./rsv-immutability-readiness-check.sh          # 5 parallel vaults
#   DEBUG=1 ./rsv-immutability-readiness-check.sh             # debug (3 vaults, verbose)
#   DEBUG=1 DEBUG_MAX=1 ./rsv-immutability-readiness-check.sh # debug 1 vault
# ===================================================================================================
set -e

SECONDS=0
DEBUG="${DEBUG:-0}"
DEBUG_MAX="${DEBUG_MAX:-3}"
PARALLEL="${PARALLEL:-10}"
SKIP_RECENT_HOURS="${SKIP_RECENT_HOURS:-48}"

TS=$(date +%Y%m%d-%H%M%S)
CSV_NO_EXPIRY="no-expiry-rps-${TS}.csv"
CSV_NO_POLICY="no-policy-items-${TS}.csv"
CSV_OVERLAP="no-expiry-no-policy-${TS}.csv"

TMPDIR_WORK=$(mktemp -d)

cleanup() {
  local EXIT_CODE=$?
  if [[ $EXIT_CODE -ne 0 ]]; then
    echo ""
    echo "[!] Script interrupted. Partial results may be in the CSV files."
  fi
  rm -rf "$TMPDIR_WORK"
}
trap cleanup EXIT

echo "============================================="
echo " RSV Immutability Readiness Check"
echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================="

# ---- Cutoff for recent RPs ----
if [[ "$SKIP_RECENT_HOURS" -gt 0 ]]; then
  CUTOFF_TS=$(date -u -d "${SKIP_RECENT_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
    || date -u -v-${SKIP_RECENT_HOURS}H +%Y-%m-%dT%H:%M:%S)
  echo "[*] Skipping RPs newer than $CUTOFF_TS (last ${SKIP_RECENT_HOURS}h)"
else
  CUTOFF_TS=""
  echo "[*] No age filter — reporting all no-expiry RPs"
fi

if [[ "$DEBUG" == "1" ]]; then
  echo "[*] DEBUG MODE — max $DEBUG_MAX vaults, verbose"
fi
echo ""

# =============================================================================
# PHASE 1: Recovery points with no expiry (via az CLI per-vault)
# =============================================================================
echo "subscription,resourceGroup,vaultName,itemName,recoveryPointTime,recoveryPointType" > "$CSV_NO_EXPIRY"

echo "[Phase 1/3] Fetching all RSV vaults via Azure Resource Graph..."
T1=$SECONDS

ALL_VAULTS=""
SKIP=0
while true; do
  PAGE_JSON=$(az graph query -q "
  Resources
  | where type =~ 'microsoft.recoveryservices/vaults'
  | project subscriptionId, resourceGroup, vaultName = name
  " --first 1000 --skip $SKIP 2>/dev/null)

  PAGE_ITEMS=$(echo "$PAGE_JSON" | jq -r '.data[] | [.subscriptionId, .resourceGroup, .vaultName] | @tsv' | tr -d '\r')
  PAGE_COUNT=$(echo "$PAGE_JSON" | jq '.data | length')

  if [[ -n "$PAGE_ITEMS" ]]; then
    if [[ -n "$ALL_VAULTS" ]]; then
      ALL_VAULTS="$ALL_VAULTS"$'\n'"$PAGE_ITEMS"
    else
      ALL_VAULTS="$PAGE_ITEMS"
    fi
  fi

  [[ "$PAGE_COUNT" -lt 1000 ]] && break
  SKIP=$((SKIP + 1000))
done

if [[ -z "$ALL_VAULTS" ]]; then
  echo "[!] No RSV vaults found."
  exit 0
fi

VAULT_COUNT=$(echo "$ALL_VAULTS" | wc -l | tr -d ' ')
echo "[*] Found $VAULT_COUNT vaults ($((SECONDS - T1))s)"
echo "[*] Scanning recovery points ($PARALLEL parallel workers)..."

# ---- Worker function ----
process_vault() {
  local VAULT_NUM="$1" VAULT_TOTAL="$2" SUB_ID="$3" RG="$4" VAULT_NAME="$5"
  local VAULT_TMPFILE="$TMPDIR_WORK/vault-${VAULT_NUM}.csv"
  local VAULT_LOG="$TMPDIR_WORK/vault-${VAULT_NUM}.log"
  local DEBUG="$6" VAULT_START=$SECONDS

  echo "  [$VAULT_NUM/$VAULT_TOTAL] $VAULT_NAME (sub=$SUB_ID)" >> "$VAULT_LOG"

  local ITEMS_JSON
  ITEMS_JSON=$(az backup item list \
    --subscription "$SUB_ID" \
    --resource-group "$RG" \
    --vault-name "$VAULT_NAME" \
    --backup-management-type AzureIaasVM \
    --workload-type VM \
    -o json 2>/dev/null) || { echo "    [!] Failed to list items" >> "$VAULT_LOG"; return; }

  if ! echo "$ITEMS_JSON" | jq empty 2>/dev/null; then
    echo "    [!] Invalid JSON from item list" >> "$VAULT_LOG"
    return
  fi

  local ITEM_COUNT
  ITEM_COUNT=$(echo "$ITEMS_JSON" | jq 'length')
  [[ "$ITEM_COUNT" -eq 0 || "$ITEM_COUNT" == "null" ]] && return

  local ITEM_LINES
  ITEM_LINES=$(echo "$ITEMS_JSON" | jq -r '.[] | [
    .properties.containerName,
    .name,
    (.properties.containerName | split(";") | last),
    (.name | split(";") | last)
  ] | @tsv' | tr -d '\r')

  local ITEM_NUM=0
  while IFS=$'\t' read -r CONTAINER_NAME ITEM_NAME FRIENDLY_CONTAINER FRIENDLY_ITEM; do
    ITEM_NUM=$((ITEM_NUM + 1))

    if [[ "$DEBUG" == "1" ]]; then
      echo "    [$ITEM_NUM/$ITEM_COUNT] $FRIENDLY_ITEM" >> "$VAULT_LOG"

      local RAW_RP
      RAW_RP=$(az backup recoverypoint list \
        --subscription "$SUB_ID" \
        --resource-group "$RG" \
        --vault-name "$VAULT_NAME" \
        --container-name "$FRIENDLY_CONTAINER" \
        --item-name "$FRIENDLY_ITEM" \
        --backup-management-type AzureIaasVM \
        --workload-type VM \
        -o json 2>&1) || { echo "      [!] FAILED: ${RAW_RP:0:200}" >> "$VAULT_LOG"; continue; }

      if ! echo "$RAW_RP" | jq empty 2>/dev/null; then
        echo "      [!] Invalid JSON: ${RAW_RP:0:200}" >> "$VAULT_LOG"
        continue
      fi

      local NO_EXPIRY
      NO_EXPIRY=$(echo "$RAW_RP" | jq -r '.[] | select(.properties.recoveryPointProperties.expiryTime == null) | [.name, .properties.recoveryPointTime, .properties.recoveryPointType] | @tsv' 2>/dev/null | tr -d '\r') || true
    else
      local NO_EXPIRY
      NO_EXPIRY=$(az backup recoverypoint list \
        --subscription "$SUB_ID" \
        --resource-group "$RG" \
        --vault-name "$VAULT_NAME" \
        --container-name "$FRIENDLY_CONTAINER" \
        --item-name "$FRIENDLY_ITEM" \
        --backup-management-type AzureIaasVM \
        --workload-type VM \
        --query "[?properties.recoveryPointProperties.expiryTime==null].{name:name, recoveryPointTime:properties.recoveryPointTime, type:properties.recoveryPointType}" \
        -o tsv 2>/dev/null | tr -d '\r') || continue
    fi

    [[ -z "$NO_EXPIRY" ]] && continue

    while IFS=$'\t' read -r RP_NAME RP_TIME RP_TYPE; do
      if [[ -n "$CUTOFF_TS" && "$RP_TIME" > "$CUTOFF_TS" ]]; then
        [[ "$DEBUG" == "1" ]] && echo "      [skip] $RP_NAME ($RP_TIME) — newer than cutoff" >> "$VAULT_LOG"
        continue
      fi
      echo "    [!] Found: $FRIENDLY_ITEM / $RP_NAME ($RP_TIME)" >> "$VAULT_LOG"
      echo "\"$SUB_ID\",\"$RG\",\"$VAULT_NAME\",\"$ITEM_NAME\",\"$RP_TIME\",\"$RP_TYPE\"" >> "$VAULT_TMPFILE"
      # Append to main CSV immediately (single echo is atomic for short lines)
      echo "\"$SUB_ID\",\"$RG\",\"$VAULT_NAME\",\"$ITEM_NAME\",\"$RP_TIME\",\"$RP_TYPE\"" >> "$CSV_NO_EXPIRY"
    done <<< "$NO_EXPIRY"

  done <<< "$ITEM_LINES"
}

export -f process_vault
export TMPDIR_WORK CUTOFF_TS CSV_NO_EXPIRY

VAULT_NUM=0
ACTIVE_PIDS=()
COMPLETED=0

print_progress() {
  # Count completed workers (PIDs that are no longer running)
  local DONE=0
  for F in "$TMPDIR_WORK"/vault-*.log; do
    [[ -f "$F" ]] && DONE=$((DONE + 1))
  done
  printf "\r  [%d/%d vaults processed, %d active workers]" "$DONE" "$VAULT_COUNT" "${#ACTIVE_PIDS[@]}"
}

while IFS=$'\t' read -r SUB_ID RG VAULT_NAME; do
  VAULT_NUM=$((VAULT_NUM + 1))
  [[ "$DEBUG" == "1" && $VAULT_NUM -gt $DEBUG_MAX ]] && break

  process_vault "$VAULT_NUM" "$VAULT_COUNT" "$SUB_ID" "$RG" "$VAULT_NAME" "$DEBUG" &
  ACTIVE_PIDS+=($!)

  while [[ ${#ACTIVE_PIDS[@]} -ge $PARALLEL ]]; do
    NEW_PIDS=()
    for PID in "${ACTIVE_PIDS[@]}"; do
      if kill -0 "$PID" 2>/dev/null; then
        NEW_PIDS+=("$PID")
      fi
    done
    ACTIVE_PIDS=("${NEW_PIDS[@]}")
    if [[ ${#ACTIVE_PIDS[@]} -ge $PARALLEL ]]; then
      print_progress
      sleep 2
    fi
  done

done <<< "$ALL_VAULTS"

echo "[*] Waiting for workers to finish..."
while true; do
  STILL_RUNNING=0
  for PID in "${ACTIVE_PIDS[@]}"; do
    kill -0 "$PID" 2>/dev/null && STILL_RUNNING=$((STILL_RUNNING + 1))
  done
  [[ $STILL_RUNNING -eq 0 ]] && break
  print_progress
  sleep 2
done
wait
echo ""

PHASE1_COUNT=$(tail -n +2 "$CSV_NO_EXPIRY" | wc -l | tr -d ' ')
PHASE1_TIME=$((SECONDS - T1))
echo "[*] Phase 1 done: $PHASE1_COUNT no-expiry RPs found (${PHASE1_TIME}s)"
echo ""

# =============================================================================
# PHASE 2: Backup items with no policy (via ARG query)
# =============================================================================
echo "[Phase 2/3] Querying backup items with no policy via ARG..."
T2=$SECONDS

echo "subscriptionId,resourceGroup,vaultName,friendlyName,itemType,protectionState,lastBackupTime" > "$CSV_NO_POLICY"

NO_POLICY_SKIP=0
while true; do
  NP_JSON=$(az graph query -q "
  RecoveryServicesResources
  | where type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems'
  | extend vaultName = tostring(split(id, '/')[8])
  | extend policyId = tostring(properties.policyId)
  | extend policyName = tostring(properties.policyInfo.name)
  | extend protectionState = tostring(properties.currentProtectionState)
  | extend friendlyName = tostring(properties.friendlyName)
  | extend itemType = strcat(properties.backupManagementType, '/', properties.workloadType)
  | extend lastBackupTime = tostring(properties.lastBackupTime)
  | where isempty(policyId) and isempty(policyName)
  | project subscriptionId, resourceGroup, vaultName, friendlyName, itemType, protectionState, lastBackupTime
  " --first 1000 --skip $NO_POLICY_SKIP 2>/dev/null)

  NP_ITEMS=$(echo "$NP_JSON" | jq -r '.data[] | [.subscriptionId, .resourceGroup, .vaultName, .friendlyName, .itemType, .protectionState, .lastBackupTime] | @csv' | tr -d '\r')
  NP_COUNT=$(echo "$NP_JSON" | jq '.data | length')

  [[ -n "$NP_ITEMS" ]] && echo "$NP_ITEMS" >> "$CSV_NO_POLICY"

  [[ "$NP_COUNT" -lt 1000 ]] && break
  NO_POLICY_SKIP=$((NO_POLICY_SKIP + 1000))
done

PHASE2_COUNT=$(tail -n +2 "$CSV_NO_POLICY" | wc -l | tr -d ' ')
echo "[*] Phase 2 done: $PHASE2_COUNT items with no policy ($((SECONDS - T2))s)"
echo ""

# =============================================================================
# PHASE 3: Cross-reference — items in BOTH lists (the real risk)
# =============================================================================
echo "[Phase 3/3] Cross-referencing no-expiry RPs with no-policy items..."

echo "subscriptionId,resourceGroup,vaultName,friendlyName,itemType,protectionState,lastBackupTime,noExpiryRpCount,oldestNoExpiryRp" > "$CSV_OVERLAP"

# Build lookup: lowercase VM name → no-expiry RP count + oldest date
declare -A RP_COUNTS
declare -A RP_OLDEST
while IFS=',' read -r SUB RG VAULT ITEM RP_TIME RP_TYPE; do
  # Extract VM name (last segment of itemName after last semicolon)
  VM_KEY=$(echo "$ITEM" | sed 's/"//g' | awk -F';' '{print tolower($NF)}')
  VAULT_CLEAN=$(echo "$VAULT" | sed 's/"//g')
  LOOKUP="${VAULT_CLEAN}|${VM_KEY}"

  RP_COUNTS[$LOOKUP]=$(( ${RP_COUNTS[$LOOKUP]:-0} + 1 ))

  RP_TIME_CLEAN=$(echo "$RP_TIME" | sed 's/"//g')
  if [[ -z "${RP_OLDEST[$LOOKUP]}" || "$RP_TIME_CLEAN" < "${RP_OLDEST[$LOOKUP]}" ]]; then
    RP_OLDEST[$LOOKUP]="$RP_TIME_CLEAN"
  fi
done < <(tail -n +2 "$CSV_NO_EXPIRY")

# Match against no-policy items
OVERLAP_COUNT=0
while IFS=',' read -r SUB RG VAULT FNAME ITYPE PSTATE LBT; do
  VAULT_CLEAN=$(echo "$VAULT" | sed 's/"//g')
  FNAME_CLEAN=$(echo "$FNAME" | sed 's/"//g' | tr '[:upper:]' '[:lower:]')
  LOOKUP="${VAULT_CLEAN}|${FNAME_CLEAN}"

  if [[ -n "${RP_COUNTS[$LOOKUP]}" ]]; then
    OVERLAP_COUNT=$((OVERLAP_COUNT + 1))
    echo "$SUB,$RG,$VAULT,$FNAME,$ITYPE,$PSTATE,$LBT,\"${RP_COUNTS[$LOOKUP]}\",\"${RP_OLDEST[$LOOKUP]}\"" >> "$CSV_OVERLAP"
  fi
done < <(tail -n +2 "$CSV_NO_POLICY")

echo "[*] Phase 3 done: $OVERLAP_COUNT items with no policy AND no-expiry RPs"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
# Count breakdowns
NP_VM_COUNT=$(tail -n +2 "$CSV_NO_POLICY" | grep -i 'AzureIaasVM' | wc -l | tr -d ' ')
NP_OTHER_COUNT=$((PHASE2_COUNT - NP_VM_COUNT))
OVERLAP_RP_TOTAL=0
for V in "${RP_COUNTS[@]}"; do OVERLAP_RP_TOTAL=$((OVERLAP_RP_TOTAL + V)); done 2>/dev/null
# Only count overlap RPs
OVERLAP_RP_SUM=0
while IFS=',' read -r _ _ _ _ _ _ _ CNT _; do
  CNT_CLEAN=$(echo "$CNT" | sed 's/"//g')
  OVERLAP_RP_SUM=$((OVERLAP_RP_SUM + CNT_CLEAN))
done < <(tail -n +2 "$CSV_OVERLAP")

# Unique vaults with no-expiry RPs
VAULTS_WITH_NOEXPIRY=$(tail -n +2 "$CSV_NO_EXPIRY" | awk -F',' '{print $3}' | sort -u | wc -l | tr -d ' ')

echo "============================================="
echo " SUMMARY — RSV Immutability Readiness"
echo "============================================="
echo ""
printf "  %-45s %s\n" "Total RSV vaults scanned:" "$VAULT_COUNT"
printf "  %-45s %s\n" "Skip recent hours:" "${SKIP_RECENT_HOURS}h"
[[ -n "$CUTOFF_TS" ]] && printf "  %-45s %s\n" "Cutoff timestamp:" "$CUTOFF_TS"
echo ""
echo "  ── Phase 1: Recovery Points with No Expiry ──"
printf "  %-45s %s\n" "No-expiry RPs (older than ${SKIP_RECENT_HOURS}h):" "$PHASE1_COUNT"
printf "  %-45s %s\n" "Across vaults:" "$VAULTS_WITH_NOEXPIRY"
echo ""
echo "  ── Phase 2: Backup Items with No Policy ─────"
printf "  %-45s %s\n" "Total items with no policy:" "$PHASE2_COUNT"
printf "  %-45s %s\n" "  VMs (AzureIaasVM):" "$NP_VM_COUNT"
printf "  %-45s %s\n" "  Other (FileShare, SAP, etc.):" "$NP_OTHER_COUNT"
echo ""
echo "  ── Phase 3: RISK — No Policy + No Expiry ────"
printf "  %-45s %s\n" "Items with no policy AND no-expiry RPs:" "$OVERLAP_COUNT"
printf "  %-45s %s\n" "Total no-expiry RPs for those items:" "$OVERLAP_RP_SUM"
echo ""
if [[ "$OVERLAP_COUNT" -gt 0 ]]; then
  echo "  ⚠  ACTION REQUIRED before locking immutability!"
  echo "     These items have stopped protection, no policy,"
  echo "     and recovery points that will never expire."
  echo "     Review: $CSV_OVERLAP"
else
  echo "  ✓  No overlap found — no-expiry RPs appear to be"
  echo "     policy-managed (weekly/monthly/yearly retention)."
fi
echo ""
echo "  ── Output Files ──────────────────────────────"
echo "  1) $CSV_NO_EXPIRY"
echo "  2) $CSV_NO_POLICY"
echo "  3) $CSV_OVERLAP"
echo ""
echo "  Total execution time: ${SECONDS}s"
echo "============================================="
