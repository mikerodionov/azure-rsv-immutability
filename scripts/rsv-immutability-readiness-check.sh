#!/bin/bash
# ===================================================================================================
# RSV Immutability Readiness Check
# Produces up to 6 CSVs + summary table to assess readiness for vault locking.
# All CSVs are written on-the-fly so partial data survives crashes.
#
# Output files (in ../rsv-reports/ one level above repo, timestamped):
#   1) no-expiry-rps-YYYYMMDD-HHMMSS.csv        — All recovery points with no expiry date
#   2) no-policy-items-YYYYMMDD-HHMMSS.csv      — Backup items with no policy assigned
#   3) no-expiry-no-policy-YYYYMMDD-HHMMSS.csv  — Items in BOTH (the real risk)
#   4) old-no-expiry-rps-YYYYMMDD-HHMMSS.csv    — No-expiry RPs older than RP_AGE_MONTHS
#   5) clean-vaults-YYYYMMDD-HHMMSS.csv         — Vaults not appearing in reports 3 or 4
#   6) dirty-vaults-YYYYMMDD-HHMMSS.csv         — Vaults appearing in report 3 or 4
#
# Usage:
#   ./scripts/rsv-immutability-readiness-check.sh                     # default (10 parallel, skip last 48h)
#   SKIP_RECENT_HOURS=0 ./scripts/rsv-immutability-readiness-check.sh # include all RPs
#   PARALLEL=5 ./scripts/rsv-immutability-readiness-check.sh          # 5 parallel vaults
#   DEBUG=1 ./scripts/rsv-immutability-readiness-check.sh             # debug (3 vaults, verbose)
#   DEBUG=1 DEBUG_MAX=1 ./scripts/rsv-immutability-readiness-check.sh # debug 1 vault
#   RP_AGE_MONTHS=6 ./scripts/rsv-immutability-readiness-check.sh     # old RPs threshold: 6 months
#   CSV_OUTPUT=0 ./scripts/rsv-immutability-readiness-check.sh        # summary only, no CSV files
#   VAULT_TIMEOUT=600 ./scripts/rsv-immutability-readiness-check.sh   # 10min timeout per vault
#
# Notes:
#   - Default PARALLEL=10 balances throughput vs Azure API throttling; raising it often slows runs.
#   - Phase 1: each worker writes vault-N.csv only; parent appends to the main CSV when that worker exits
#     (single-writer — safe; parallel >> to one file would corrupt CSVs).
#   - Requires python3 for CSV phases (RFC-safe parsing); az, jq, bash 4+ as before.
# ===================================================================================================
set -e

SECONDS=0
DEBUG="${DEBUG:-0}"
DEBUG_MAX="${DEBUG_MAX:-3}"
PARALLEL="${PARALLEL:-10}"
SKIP_RECENT_HOURS="${SKIP_RECENT_HOURS:-48}"
RP_AGE_MONTHS="${RP_AGE_MONTHS:-13}"
CSV_OUTPUT="${CSV_OUTPUT:-1}"
VAULT_TIMEOUT="${VAULT_TIMEOUT:-600}"

# ---- Helper: human-readable elapsed time ----
format_time() {
  local SECS=$1
  if [[ $SECS -lt 60 ]]; then
    echo "${SECS}s"
  else
    echo "$((SECS / 60))m $((SECS % 60))s"
  fi
}

require_python3() {
  command -v python3 >/dev/null 2>&1 || {
    echo "[!] python3 is required for CSV filtering/join steps (RFC-safe parsing)." >&2
    exit 1
  }
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPORT_DIR="$(cd "$REPO_ROOT/.." && pwd)/rsv-reports"
mkdir -p "$REPORT_DIR"

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

TS=$(date +%Y%m%d-%H%M%S)

# All CSVs go to report dir when enabled (crash-safe, on-the-fly writes survive)
# When disabled, everything goes to temp (discarded on exit)
if [[ "$CSV_OUTPUT" == "1" ]]; then
  CSV_NO_EXPIRY="${REPORT_DIR}/no-expiry-rps-${TS}.csv"
  CSV_NO_POLICY="${REPORT_DIR}/no-policy-items-${TS}.csv"
  CSV_OVERLAP="${REPORT_DIR}/no-expiry-no-policy-${TS}.csv"
  CSV_OLD_RPS="${REPORT_DIR}/old-no-expiry-rps-${TS}.csv"
  CSV_CLEAN="${REPORT_DIR}/clean-vaults-${TS}.csv"
  CSV_DIRTY="${REPORT_DIR}/dirty-vaults-${TS}.csv"
else
  CSV_NO_EXPIRY="${TMPDIR_WORK}/no-expiry-rps.csv"
  CSV_NO_POLICY="${TMPDIR_WORK}/no-policy-items.csv"
  CSV_OVERLAP="${TMPDIR_WORK}/no-expiry-no-policy.csv"
  CSV_OLD_RPS="${TMPDIR_WORK}/old-no-expiry-rps.csv"
  CSV_CLEAN="${TMPDIR_WORK}/clean-vaults.csv"
  CSV_DIRTY="${TMPDIR_WORK}/dirty-vaults.csv"
fi

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

# ---- Cutoff for old RPs report ----
RP_AGE_CUTOFF=$(date -u -d "${RP_AGE_MONTHS} months ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
  || date -u -v-${RP_AGE_MONTHS}m +%Y-%m-%dT%H:%M:%S)
echo "[*] Old RP threshold: ${RP_AGE_MONTHS} months (before $RP_AGE_CUTOFF)"
echo "[*] Per-vault timeout: ${VAULT_TIMEOUT}s"

require_python3

if [[ "$DEBUG" == "1" ]]; then
  echo "[*] DEBUG MODE — max $DEBUG_MAX vaults, verbose"
fi
echo ""

# =============================================================================
# PHASE 1: Recovery points with no expiry (via az CLI per-vault)
# =============================================================================
echo "subscription,resourceGroup,vaultName,itemName,recoveryPointTime,recoveryPointType" > "$CSV_NO_EXPIRY"

echo "[Phase 1/4] Fetching all RSV vaults via Azure Resource Graph..."
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
echo "[*] Found $VAULT_COUNT vaults ($(format_time $((SECONDS - T1))))"
echo "[*] Scanning recovery points ($PARALLEL parallel workers)..."

# ---- Worker function ----
process_vault() {
  local VAULT_NUM="$1" VAULT_TOTAL="$2" SUB_ID="$3" RG="$4" VAULT_NAME="$5"
  local VAULT_TMPFILE="$TMPDIR_WORK/vault-${VAULT_NUM}.csv"
  local VAULT_LOG="$TMPDIR_WORK/vault-${VAULT_NUM}.log"
  local DEBUG="$6" VAULT_START=$SECONDS

  : > "$VAULT_TMPFILE"

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
    done <<< "$NO_EXPIRY"

  done <<< "$ITEM_LINES"
}

export -f process_vault
export TMPDIR_WORK CUTOFF_TS

VAULT_NUM=0
ACTIVE_PIDS=()
declare -A PID_START_TIMES
declare -A PID_VAULT_NAMES
declare -A PID_TO_VAULT_NUM
declare -A MERGED_VAULT_CSV

# When a worker exits, append its temp file once (parent only — keeps no-expiry CSV populated during the run).
merge_completed_workers() {
  local NEW_PIDS=() pid vn
  for pid in "${ACTIVE_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      NEW_PIDS+=("$pid")
    else
      vn="${PID_TO_VAULT_NUM[$pid]}"
      if [[ -n "$vn" && -z "${MERGED_VAULT_CSV[$vn]}" ]]; then
        [[ -s "$TMPDIR_WORK/vault-${vn}.csv" ]] && cat "$TMPDIR_WORK/vault-${vn}.csv" >> "$CSV_NO_EXPIRY"
        MERGED_VAULT_CSV[$vn]=1
      fi
      wait "$pid" 2>/dev/null || true
    fi
  done
  ACTIVE_PIDS=("${NEW_PIDS[@]}")
}

print_progress() {
  local ACTIVE=0
  for PID in "${ACTIVE_PIDS[@]}"; do
    kill -0 "$PID" 2>/dev/null && ACTIVE=$((ACTIVE + 1))
  done
  local DONE=$((VAULT_NUM - ACTIVE))
  printf "\r  [%d/%d vaults completed, %d active workers]" "$DONE" "$VAULT_COUNT" "$ACTIVE"
}

kill_stale_workers() {
  local NOW=$SECONDS
  for PID in "${ACTIVE_PIDS[@]}"; do
    if kill -0 "$PID" 2>/dev/null; then
      local ELAPSED=$((NOW - ${PID_START_TIMES[$PID]:-$NOW}))
      if [[ $ELAPSED -ge $VAULT_TIMEOUT ]]; then
        echo "[!] TIMEOUT: ${PID_VAULT_NAMES[$PID]} after ${ELAPSED}s (PID $PID)" >> "$TMPDIR_WORK/timeouts.log"
        kill -9 "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
      fi
    fi
  done
}

while IFS=$'\t' read -r SUB_ID RG VAULT_NAME; do
  VAULT_NUM=$((VAULT_NUM + 1))
  [[ "$DEBUG" == "1" && $VAULT_NUM -gt $DEBUG_MAX ]] && break

  process_vault "$VAULT_NUM" "$VAULT_COUNT" "$SUB_ID" "$RG" "$VAULT_NAME" "$DEBUG" &
  WORKER_PID=$!
  ACTIVE_PIDS+=($WORKER_PID)
  PID_START_TIMES[$WORKER_PID]=$SECONDS
  PID_VAULT_NAMES[$WORKER_PID]="$VAULT_NAME"
  PID_TO_VAULT_NUM[$WORKER_PID]=$VAULT_NUM
  disown "$WORKER_PID" 2>/dev/null

  while [[ ${#ACTIVE_PIDS[@]} -ge $PARALLEL ]]; do
    kill_stale_workers
    merge_completed_workers
    if [[ ${#ACTIVE_PIDS[@]} -ge $PARALLEL ]]; then
      print_progress
      sleep 2
    fi
  done

done <<< "$ALL_VAULTS"

# Wait for remaining workers to finish
while true; do
  kill_stale_workers
  merge_completed_workers
  STILL_RUNNING=${#ACTIVE_PIDS[@]}
  [[ $STILL_RUNNING -eq 0 ]] && break
  local_done=$((VAULT_NUM - STILL_RUNNING))
  printf "\r  [%d/%d vaults completed, %d active workers]" "$local_done" "$VAULT_COUNT" "$STILL_RUNNING"
  sleep 2
done
wait 2>/dev/null
printf "\r  [%d/%d vaults completed, 0 active workers]          \n" "$VAULT_COUNT" "$VAULT_COUNT"

# Catch any vault file not merged yet (should be rare)
echo "[*] Finalizing ${CSV_NO_EXPIRY##*/}..."
T_MERGE=$SECONDS
shopt -s nullglob
for _f in $(printf '%s\n' "$TMPDIR_WORK"/vault-*.csv 2>/dev/null | LC_ALL=C sort -V); do
  [[ -s "$_f" ]] || continue
  _bn=$(basename "$_f" .csv)
  _vn="${_bn#vault-}"
  [[ -n "${MERGED_VAULT_CSV[$_vn]}" ]] && continue
  cat "$_f" >> "$CSV_NO_EXPIRY"
  MERGED_VAULT_CSV[$_vn]=1
done
shopt -u nullglob
echo "[*] Finalize done ($(format_time $((SECONDS - T_MERGE))))"

# Report timeouts
if [[ -f "$TMPDIR_WORK/timeouts.log" ]]; then
  TIMEOUT_COUNT=$(grep -c '.' "$TMPDIR_WORK/timeouts.log" 2>/dev/null || echo 0)
  echo "[!] $TIMEOUT_COUNT vault(s) timed out after ${VAULT_TIMEOUT}s:"
  cat "$TMPDIR_WORK/timeouts.log"
  echo ""
fi

PHASE1_COUNT=$(tail -n +2 "$CSV_NO_EXPIRY" | wc -l | tr -d ' ')
PHASE1_TIME=$((SECONDS - T1))
echo "[*] Phase 1 done: $PHASE1_COUNT no-expiry RPs found ($(format_time $PHASE1_TIME))"
echo ""

# =============================================================================
# PHASE 1.5: No-expiry RPs older than RP_AGE_MONTHS
# =============================================================================
echo "[*] Filtering no-expiry RPs older than ${RP_AGE_MONTHS} months..."
T15=$SECONDS

python3 - "$RP_AGE_CUTOFF" "$CSV_NO_EXPIRY" "$CSV_OLD_RPS" <<'PY'
import csv
import sys

cutoff, inp_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
written = 0
with open(inp_path, newline="") as inf, open(out_path, "w", newline="") as outf:
    reader = csv.reader(inf)
    writer = csv.writer(outf)
    header = next(reader)
    writer.writerow(header)
    for row in reader:
        if len(row) < 6:
            continue
        rp_time = row[4]
        # ISO-8601 timestamps sort/compare lexicographically as chronology for normal formats
        if rp_time < cutoff:
            writer.writerow(row)
            written += 1
            if written % 50000 == 0:
                print(f"  ... wrote {written} old RP rows", file=sys.stderr)
PY

OLD_RP_COUNT=$(tail -n +2 "$CSV_OLD_RPS" | wc -l | tr -d ' ')
echo "[*] Found $OLD_RP_COUNT no-expiry RPs older than ${RP_AGE_MONTHS} months ($(format_time $((SECONDS - T15))))"
echo ""

# =============================================================================
# PHASE 2: Backup items with no policy (via ARG query)
# =============================================================================
echo "[Phase 2/4] Querying backup items with no policy via ARG..."
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
echo "[*] Phase 2 done: $PHASE2_COUNT items with no policy ($(format_time $((SECONDS - T2))))"
echo ""

# =============================================================================
# PHASE 3: Cross-reference — items in BOTH lists (the real risk)
# =============================================================================
echo "[Phase 3/4] Cross-referencing no-expiry RPs with no-policy items..."
T3=$SECONDS

read -r OVERLAP_COUNT OVERLAP_RP_SUM <<< "$(python3 - "$CSV_NO_EXPIRY" "$CSV_NO_POLICY" "$CSV_OVERLAP" <<'PY'
import csv
import sys
from collections import defaultdict

no_expiry_path, no_policy_path, overlap_path = sys.argv[1], sys.argv[2], sys.argv[3]


def vm_key_from_item(item: str) -> str:
    parts = item.split(";")
    return parts[-1].lower() if parts else item.lower()


rp_counts = defaultdict(int)
rp_oldest = {}

with open(no_expiry_path, newline="") as f:
    r = csv.reader(f)
    next(r)
    idx = 0
    for row in r:
        idx += 1
        if idx % 500 == 0:
            print(f"\r  [{idx} RPs indexed]", end="", file=sys.stderr)
        if len(row) < 6:
            continue
        _sub, _rg, vault, item, rp_time, _rp_type = row[:6]
        lk = f"{vault}|{vm_key_from_item(item)}"
        rp_counts[lk] += 1
        if lk not in rp_oldest or rp_time < rp_oldest[lk]:
            rp_oldest[lk] = rp_time

overlap_count = 0
overlap_rp_sum = 0

with open(no_policy_path, newline="") as inf, open(overlap_path, "w", newline="") as outf:
    r = csv.reader(inf)
    w = csv.writer(outf)
    next(r)  # skip ARG header in file
    w.writerow(
        [
            "subscriptionId",
            "resourceGroup",
            "vaultName",
            "friendlyName",
            "itemType",
            "protectionState",
            "lastBackupTime",
            "noExpiryRpCount",
            "oldestNoExpiryRp",
        ]
    )
    ni = 0
    for row in r:
        ni += 1
        if ni % 200 == 0:
            print(
                f"\r  [{ni} items checked, {overlap_count} overlaps]",
                end="",
                file=sys.stderr,
            )
        if len(row) < 7:
            continue
        sub, rg, vault, fname, itype, pstate, lbt = row[:7]
        lk = f"{vault}|{fname.lower()}"
        if lk not in rp_counts:
            continue
        overlap_count += 1
        cnt = rp_counts[lk]
        overlap_rp_sum += cnt
        w.writerow(row + [str(cnt), rp_oldest[lk]])

print("", file=sys.stderr)
print(f"{overlap_count} {overlap_rp_sum}")
PY
)"

PHASE3_TIME=$((SECONDS - T3))
echo "[*] Phase 3 done: $OVERLAP_COUNT items with no policy AND no-expiry RPs ($(format_time $PHASE3_TIME))"
echo ""

# =============================================================================
# PHASE 4: Clean and Dirty vault classification
# =============================================================================
echo "[Phase 4/4] Classifying clean and dirty vaults..."
T4=$SECONDS

printf '%s\n' "$ALL_VAULTS" > "$TMPDIR_WORK/all-vaults.tsv"

python3 - "$TMPDIR_WORK/all-vaults.tsv" "$CSV_OVERLAP" "$CSV_OLD_RPS" "$CSV_DIRTY" "$CSV_CLEAN" <<'PY'
import csv
import sys

vaults_path, overlap_path, old_path, dirty_path, clean_path = sys.argv[1:6]


def vault_keys(csv_path: str, skip_header: bool = True):
    with open(csv_path, newline="") as f:
        r = csv.reader(f)
        if skip_header:
            next(r, None)
        for row in r:
            if len(row) >= 3:
                yield row[0], row[1], row[2]


dirty_overlap = set()
for sub, rg, v in vault_keys(overlap_path):
    dirty_overlap.add((sub, rg, v))

dirty_old = set()
for sub, rg, v in vault_keys(old_path):
    dirty_old.add((sub, rg, v))

all_dirty = dirty_overlap | dirty_old

with open(dirty_path, "w", newline="") as df:
    dw = csv.writer(df)
    dw.writerow(["subscription", "resourceGroup", "vaultName", "reason"])
    for sub, rg, v in sorted(all_dirty):
        reasons = []
        if (sub, rg, v) in dirty_overlap:
            reasons.append("no-policy-no-expiry")
        if (sub, rg, v) in dirty_old:
            reasons.append("old-no-expiry-rps")
        dw.writerow([sub, rg, v, ";".join(reasons)])

dirty_set = all_dirty

with open(vaults_path, newline="") as vf, open(clean_path, "w", newline="") as cf:
    r = csv.reader(vf, delimiter="\t")
    cw = csv.writer(cf)
    cw.writerow(["subscription", "resourceGroup", "vaultName"])
    for row in r:
        if len(row) < 3:
            continue
        sub, rg, v = row[0], row[1], row[2]
        if (sub, rg, v) not in dirty_set:
            cw.writerow([sub, rg, v])
PY

DIRTY_COUNT=$(tail -n +2 "$CSV_DIRTY" | wc -l | tr -d ' ')
CLEAN_COUNT=$(tail -n +2 "$CSV_CLEAN" | wc -l | tr -d ' ')
echo "[*] Phase 4 done: $CLEAN_COUNT clean vaults, $DIRTY_COUNT dirty vaults ($(format_time $((SECONDS - T4))))"
echo ""

# =============================================================================
# SUMMARY
# =============================================================================
# Count breakdowns (OVERLAP_RP_SUM is set from Phase 3 stdout)
NP_VM_COUNT=$(tail -n +2 "$CSV_NO_POLICY" | grep -i 'AzureIaasVM' | wc -l | tr -d ' ')
NP_OTHER_COUNT=$((PHASE2_COUNT - NP_VM_COUNT))

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
echo "  ── Old No-Expiry RPs (>${RP_AGE_MONTHS} months) ──────"
printf "  %-45s %s\n" "No-expiry RPs older than ${RP_AGE_MONTHS} months:" "$OLD_RP_COUNT"
echo ""
echo "  ── Phase 4: Vault Classification ─────────────"
printf "  %-45s %s\n" "Clean vaults (not in reports 3 or 4):" "$CLEAN_COUNT"
printf "  %-45s %s\n" "Dirty vaults (in report 3 or 4):" "$DIRTY_COUNT"
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
if [[ "$CSV_OUTPUT" == "1" ]]; then
  echo "  1) $CSV_NO_EXPIRY"
  echo "  2) $CSV_NO_POLICY"
  echo "  3) $CSV_OVERLAP"
  echo "  4) $CSV_OLD_RPS"
  echo "  5) $CSV_CLEAN"
  echo "  6) $CSV_DIRTY"
else
  echo "  (CSV output disabled — set CSV_OUTPUT=1 to generate files)"
fi
echo ""
echo "  Total execution time: $(format_time $SECONDS)"
echo "============================================="
