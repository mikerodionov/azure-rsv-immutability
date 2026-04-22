#!/bin/bash
# ===================================================================================================
# RSV Immutability Readiness Check
# Produces up to 9 CSVs + summary table to assess readiness for vault locking.
# All CSVs are written on-the-fly so partial data survives crashes.
#
# Output files (in ../rsv-reports/ one level above repo, timestamped):
#   1) 1-no-expiry-rps-YYYYMMDD-HHMMSS.csv      — Recovery points with null expiryTime (after SKIP_RECENT_HOURS)
#   2) 2-no-policy-items-YYYYMMDD-HHMMSS.csv    — Backup items with no policy assigned (ARG)
#   3) 3-no-expiry-no-policy-YYYYMMDD-HHMMSS.csv — Items in BOTH 1∩2 — primary lock risk
#   4) 4-old-rps-YYYYMMDD-HHMMSS.csv            — Recovery points with recoveryPointTime before RP_AGE_CUTOFF (any expiry)
#   5) 5-clean-vaults-YYYYMMDD-HHMMSS.csv       — Vaults in neither report 3 nor 4 (safe to review for lock)
#   6) 6-dirty-vaults-YYYYMMDD-HHMMSS.csv       — Vaults in report 3 OR 4 OR timed out — reasons include timeout
#   7) 7-timed-out-vaults-YYYYMMDD-HHMMSS.csv   — Vault workers killed after VAULT_TIMEOUT
#   8) 8-final-clean-vaults-YYYYMMDD-HHMMSS.csv — Authoritative clean set after timeout retry reconciliation
#   9) 9-final-dirty-vaults-YYYYMMDD-HHMMSS.csv — Authoritative dirty set after timeout retry reconciliation
#
# Dirty vault rule: overlap (no policy ∧ still has no-expiry RPs in this scan), OR any RP older than RP_AGE_MONTHS (report 4).
# Report 1 still lists only null-expiry RPs; report 4 lists any RP past the age threshold (see expiryTime column).
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
#   RETRY_VAULTS_CSV=../rsv-reports/7-timed-out-vaults-*.csv PARALLEL=5 VAULT_TIMEOUT=1200 ./scripts/rsv-immutability-readiness-check.sh
#   AUTO_RETRY_TIMEOUTS=1 ./scripts/rsv-immutability-readiness-check.sh # default: auto retry timed-out vaults once
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
RETRY_VAULTS_CSV="${RETRY_VAULTS_CSV:-}"
AUTO_RETRY_TIMEOUTS="${AUTO_RETRY_TIMEOUTS:-1}"
AUTO_RETRY_PARALLEL="${AUTO_RETRY_PARALLEL:-5}"
AUTO_RETRY_TIMEOUT="${AUTO_RETRY_TIMEOUT:-1200}"
RETRY_RESULT_META="${RETRY_RESULT_META:-}"

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

require_python_pip_module() {
  # Cross-platform: just check if any pip variant works
  if pip3 --version >/dev/null 2>&1 || pip --version >/dev/null 2>&1 \
     || python3 -m pip --version >/dev/null 2>&1 || python -m pip --version >/dev/null 2>&1; then
    return 0
  fi

  echo "[!] pip is required but not found." >&2
  echo "[!] None of: pip3, pip, python3 -m pip, python -m pip worked." >&2

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      fedora|rhel|centos|rocky|almalinux)
        echo "[!] Suggested fix: sudo dnf install -y python3-pip" >&2 ;;
      ubuntu|debian|linuxmint|pop)
        echo "[!] Suggested fix: sudo apt-get update && sudo apt-get install -y python3-pip" >&2 ;;
      opensuse*|sles)
        echo "[!] Suggested fix: sudo zypper install -y python3-pip" >&2 ;;
      alpine)
        echo "[!] Suggested fix: sudo apk add py3-pip" >&2 ;;
      arch|manjaro)
        echo "[!] Suggested fix: sudo pacman -Sy --noconfirm python-pip" >&2 ;;
      *)
        echo "[!] Suggested fix: install pip for your distro." >&2 ;;
    esac
  else
    case "$(uname -s 2>/dev/null || echo unknown)" in
      Darwin)
        echo "[!] Suggested fix: brew install python" >&2 ;;
      MINGW*|MSYS*|CYGWIN*)
        echo "[!] Suggested fix: scoop install python  OR  winget install Python.Python.3" >&2 ;;
      *)
        echo "[!] Suggested fix: install pip for your OS." >&2 ;;
    esac
  fi

  exit 1
}

require_azure_graph_ready() {
  command -v az >/dev/null 2>&1 || {
    echo "[!] Azure CLI (az) is required." >&2
    exit 1
  }

  az account show >/dev/null 2>&1 || {
    echo "[!] Azure CLI is not authenticated. Run: az login" >&2
    exit 1
  }

  # Ensure ARG extension is available to avoid hidden interactive prompts later.
  if ! az extension show -n resource-graph >/dev/null 2>&1; then
    echo "[*] Installing Azure CLI extension: resource-graph ..."
    # Force non-interactive extension behavior for private/local tenants.
    az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1 || true
    az config set extension.dynamic_install_allow_preview=false >/dev/null 2>&1 || true
    local EXT_ERR="$TMPDIR_WORK/az-resource-graph-install.err"
    az extension add -n resource-graph --allow-preview false --only-show-errors >/dev/null 2>"$EXT_ERR" || {
      echo "[!] Failed to install resource-graph extension." >&2
      if [[ -s "$EXT_ERR" ]]; then
        echo "[!] Azure CLI output (install failure):" >&2
        sed -n '1,8p' "$EXT_ERR" >&2
      fi
      echo "[!] Install manually: az extension add -n resource-graph" >&2
      exit 1
    }
  fi

  # Fail fast with a clear message if ARG itself is unavailable.
  az graph query -q "Resources | project id | limit 1" --first 1 >/dev/null 2>&1 || {
    echo "[!] Azure Resource Graph query failed." >&2
    echo "[!] Verify subscription access/permissions and extension state." >&2
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
  CSV_NO_EXPIRY="${REPORT_DIR}/1-no-expiry-rps-${TS}.csv"
  CSV_NO_POLICY="${REPORT_DIR}/2-no-policy-items-${TS}.csv"
  CSV_OVERLAP="${REPORT_DIR}/3-no-expiry-no-policy-${TS}.csv"
  CSV_OLD_RPS="${REPORT_DIR}/4-old-rps-${TS}.csv"
  CSV_CLEAN="${REPORT_DIR}/5-clean-vaults-${TS}.csv"
  CSV_DIRTY="${REPORT_DIR}/6-dirty-vaults-${TS}.csv"
  CSV_TIMEOUTS="${REPORT_DIR}/7-timed-out-vaults-${TS}.csv"
  CSV_FINAL_CLEAN="${REPORT_DIR}/8-final-clean-vaults-${TS}.csv"
  CSV_FINAL_DIRTY="${REPORT_DIR}/9-final-dirty-vaults-${TS}.csv"
else
  CSV_NO_EXPIRY="${TMPDIR_WORK}/1-no-expiry-rps.csv"
  CSV_NO_POLICY="${TMPDIR_WORK}/2-no-policy-items.csv"
  CSV_OVERLAP="${TMPDIR_WORK}/3-no-expiry-no-policy.csv"
  CSV_OLD_RPS="${TMPDIR_WORK}/4-old-rps.csv"
  CSV_CLEAN="${TMPDIR_WORK}/5-clean-vaults.csv"
  CSV_DIRTY="${TMPDIR_WORK}/6-dirty-vaults.csv"
  CSV_TIMEOUTS="${TMPDIR_WORK}/7-timed-out-vaults.csv"
  CSV_FINAL_CLEAN="${TMPDIR_WORK}/8-final-clean-vaults.csv"
  CSV_FINAL_DIRTY="${TMPDIR_WORK}/9-final-dirty-vaults.csv"
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
if [[ -z "$RETRY_VAULTS_CSV" && "$AUTO_RETRY_TIMEOUTS" == "1" ]]; then
  echo "[*] Auto timeout retry: enabled (PARALLEL=${AUTO_RETRY_PARALLEL}, VAULT_TIMEOUT=${AUTO_RETRY_TIMEOUT}s)"
fi

require_python3
require_python_pip_module
require_azure_graph_ready

if [[ "$DEBUG" == "1" ]]; then
  echo "[*] DEBUG MODE — max $DEBUG_MAX vaults, verbose"
fi
echo ""

# =============================================================================
# PHASE 1: Recovery points with no expiry (via az CLI per-vault)
# =============================================================================
echo "subscription,resourceGroup,vaultName,itemName,recoveryPointTime,recoveryPointType" > "$CSV_NO_EXPIRY"
echo "subscription,resourceGroup,vaultName,itemName,recoveryPointTime,recoveryPointType,expiryTime" > "$CSV_OLD_RPS"

echo "subscription,resourceGroup,vaultName,elapsedSeconds,pid" > "$CSV_TIMEOUTS"

if [[ -n "$RETRY_VAULTS_CSV" ]]; then
  echo "[Phase 1/4] Loading target vaults from RETRY_VAULTS_CSV..."
else
  echo "[Phase 1/4] Fetching all RSV vaults via Azure Resource Graph..."
fi
T1=$SECONDS

ALL_VAULTS=""
if [[ -n "$RETRY_VAULTS_CSV" ]]; then
  if [[ ! -f "$RETRY_VAULTS_CSV" ]]; then
    echo "[!] RETRY_VAULTS_CSV does not exist: $RETRY_VAULTS_CSV"
    exit 1
  fi
  ALL_VAULTS="$(python3 - "$RETRY_VAULTS_CSV" <<'PY'
import csv
import sys

path = sys.argv[1]
out = []
with open(path, newline="") as f:
    r = csv.reader(f)
    header = next(r, [])
    if [h.strip().lower() for h in header[:3]] != ["subscription", "resourcegroup", "vaultname"]:
        # allow files where the first row is already data
        if len(header) >= 3:
            out.append("\t".join(header[:3]))
    for row in r:
        if len(row) >= 3:
            out.append("\t".join(row[:3]))
print("\n".join(out))
PY
)"
else
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
fi

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
  local VAULT_AGED_TMPFILE="$TMPDIR_WORK/vault-${VAULT_NUM}-aged.csv"
  local VAULT_LOG="$TMPDIR_WORK/vault-${VAULT_NUM}.log"
  local DEBUG="$6" VAULT_START=$SECONDS

  : > "$VAULT_TMPFILE"
  : > "$VAULT_AGED_TMPFILE"

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

    local RAW_RP
    if [[ "$DEBUG" == "1" ]]; then
      echo "    [$ITEM_NUM/$ITEM_COUNT] $FRIENDLY_ITEM" >> "$VAULT_LOG"
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
    else
      RAW_RP=$(az backup recoverypoint list \
        --subscription "$SUB_ID" \
        --resource-group "$RG" \
        --vault-name "$VAULT_NAME" \
        --container-name "$FRIENDLY_CONTAINER" \
        --item-name "$FRIENDLY_ITEM" \
        --backup-management-type AzureIaasVM \
        --workload-type VM \
        -o json 2>/dev/null) || continue

      if ! echo "$RAW_RP" | jq empty 2>/dev/null; then
        continue
      fi
    fi

    # Report 4: any RP older than RP_AGE_CUTOFF (compare first 19 chars so Z/fractions vs cutoff align)
    echo "$RAW_RP" | jq -r --arg ac "$RP_AGE_CUTOFF" --arg sub "$SUB_ID" --arg rg "$RG" --arg vault "$VAULT_NAME" --arg item "$ITEM_NAME" '
      def head19: if type == "string" and length >= 19 then .[0:19] else . end;
      .[] | select(.properties.recoveryPointTime != null and (.properties.recoveryPointTime | type == "string")
        and ((.properties.recoveryPointTime | head19) < ($ac | head19)))
      | [$sub, $rg, $vault, $item, .properties.recoveryPointTime, (.properties.recoveryPointType // ""), (.properties.recoveryPointProperties.expiryTime // "")] | @csv
    ' >> "$VAULT_AGED_TMPFILE" 2>/dev/null || true

    local NO_EXPIRY
    NO_EXPIRY=$(echo "$RAW_RP" | jq -r '.[] | select(.properties.recoveryPointProperties.expiryTime == null) | [.name, .properties.recoveryPointTime, .properties.recoveryPointType] | @tsv' 2>/dev/null | tr -d '\r') || true

    if [[ -n "$NO_EXPIRY" ]]; then
      while IFS=$'\t' read -r RP_NAME RP_TIME RP_TYPE; do
        if [[ -n "$CUTOFF_TS" && "$RP_TIME" > "$CUTOFF_TS" ]]; then
          [[ "$DEBUG" == "1" ]] && echo "      [skip] $RP_NAME ($RP_TIME) — newer than cutoff" >> "$VAULT_LOG"
          continue
        fi
        echo "    [!] Found: $FRIENDLY_ITEM / $RP_NAME ($RP_TIME)" >> "$VAULT_LOG"
        echo "\"$SUB_ID\",\"$RG\",\"$VAULT_NAME\",\"$ITEM_NAME\",\"$RP_TIME\",\"$RP_TYPE\"" >> "$VAULT_TMPFILE"
      done <<< "$NO_EXPIRY"
    fi

  done <<< "$ITEM_LINES"
}

export -f process_vault
export TMPDIR_WORK CUTOFF_TS RP_AGE_CUTOFF

VAULT_NUM=0
ACTIVE_PIDS=()
declare -A PID_START_TIMES
declare -A PID_VAULT_NAMES
declare -A PID_SUB_IDS
declare -A PID_RESOURCE_GROUPS
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
        [[ -s "$TMPDIR_WORK/vault-${vn}-aged.csv" ]] && cat "$TMPDIR_WORK/vault-${vn}-aged.csv" >> "$CSV_OLD_RPS"
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
        echo "TIMEOUT: ${PID_VAULT_NAMES[$PID]} after ${ELAPSED}s (PID $PID)" >> "$TMPDIR_WORK/timeouts.log"
        echo "\"${PID_SUB_IDS[$PID]}\",\"${PID_RESOURCE_GROUPS[$PID]}\",\"${PID_VAULT_NAMES[$PID]}\",\"${ELAPSED}\",\"$PID\"" >> "$CSV_TIMEOUTS"
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
  PID_SUB_IDS[$WORKER_PID]="$SUB_ID"
  PID_RESOURCE_GROUPS[$WORKER_PID]="$RG"
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

# Catch any vault worker output not merged yet (should be rare)
echo "[*] Finalizing ${CSV_NO_EXPIRY##*/} and ${CSV_OLD_RPS##*/}..."
T_MERGE=$SECONDS
for ((FIN_VN=1; FIN_VN<=VAULT_NUM; FIN_VN++)); do
  [[ -n "${MERGED_VAULT_CSV[$FIN_VN]}" ]] && continue
  [[ -s "$TMPDIR_WORK/vault-${FIN_VN}.csv" ]] && cat "$TMPDIR_WORK/vault-${FIN_VN}.csv" >> "$CSV_NO_EXPIRY"
  [[ -s "$TMPDIR_WORK/vault-${FIN_VN}-aged.csv" ]] && cat "$TMPDIR_WORK/vault-${FIN_VN}-aged.csv" >> "$CSV_OLD_RPS"
  MERGED_VAULT_CSV[$FIN_VN]=1
done
echo "[*] Finalize done ($(format_time $((SECONDS - T_MERGE))))"

# Report timeouts
if [[ -f "$TMPDIR_WORK/timeouts.log" ]]; then
  TIMEOUT_COUNT=$(tail -n +2 "$CSV_TIMEOUTS" | wc -l | tr -d ' ')
  echo "[!] $TIMEOUT_COUNT vault(s) timed out after ${VAULT_TIMEOUT}s:"
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "[!] $line"
  done < "$TMPDIR_WORK/timeouts.log"
  echo ""
else
  TIMEOUT_COUNT=0
fi

PHASE1_COUNT=$(tail -n +2 "$CSV_NO_EXPIRY" | wc -l | tr -d ' ')
OLD_RP_COUNT=$(tail -n +2 "$CSV_OLD_RPS" | wc -l | tr -d ' ')
PHASE1_TIME=$((SECONDS - T1))
echo "[*] Phase 1 done: $PHASE1_COUNT no-expiry RPs (report 1); $OLD_RP_COUNT RPs older than ${RP_AGE_MONTHS} months / any expiry (report 4) ($(format_time $PHASE1_TIME))"
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
  | where protectionState != 'SoftDeleted'
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

read -r OVERLAP_COUNT <<< "$(python3 - "$CSV_NO_EXPIRY" "$CSV_NO_POLICY" "$CSV_OVERLAP" <<'PY'
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
        w.writerow(row + [str(cnt), rp_oldest[lk]])

print("", file=sys.stderr)
print(f"{overlap_count}")
PY
)"

PHASE3_TIME=$((SECONDS - T3))
echo "[*] Phase 3 done: $OVERLAP_COUNT items with no policy AND no-expiry RPs ($(format_time $PHASE3_TIME))"
echo ""

# =============================================================================
# PHASE 4: Vault classification — dirty iff vault appears in CSV #3 OR #4 (union)
# =============================================================================
echo "[Phase 4/4] Classifying clean and dirty vaults..."
T4=$SECONDS

printf '%s\n' "$ALL_VAULTS" > "$TMPDIR_WORK/all-vaults.tsv"

python3 - "$TMPDIR_WORK/all-vaults.tsv" "$CSV_OVERLAP" "$CSV_OLD_RPS" "$CSV_TIMEOUTS" "$CSV_DIRTY" "$CSV_CLEAN" <<'PY'
import csv
import sys

vaults_path, overlap_path, old_path, timeout_path, dirty_path, clean_path = sys.argv[1:7]


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

dirty_timeout = set()
for sub, rg, v in vault_keys(timeout_path):
    dirty_timeout.add((sub, rg, v))

all_dirty = dirty_overlap | dirty_old | dirty_timeout

with open(dirty_path, "w", newline="") as df:
    dw = csv.writer(df)
    dw.writerow(["subscription", "resourceGroup", "vaultName", "reason"])
    for sub, rg, v in sorted(all_dirty):
        reasons = []
        if (sub, rg, v) in dirty_overlap:
            reasons.append("no-policy-no-expiry")
        if (sub, rg, v) in dirty_old:
            reasons.append("old-rps")
        if (sub, rg, v) in dirty_timeout:
            reasons.append("timeout")
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
# Count breakdowns
NP_VM_COUNT=$(tail -n +2 "$CSV_NO_POLICY" | grep -i 'AzureIaasVM' | wc -l | tr -d ' ')
NP_OTHER_COUNT=$((PHASE2_COUNT - NP_VM_COUNT))

# Unique vaults with no-expiry RPs
VAULTS_WITH_NOEXPIRY=$(tail -n +2 "$CSV_NO_EXPIRY" | awk -F',' '{print $3}' | sort -u | wc -l | tr -d ' ')
OVERLAP_VAULT_COUNT=$(tail -n +2 "$CSV_OVERLAP" | awk -F',' '{print $3}' | sort -u | wc -l | tr -d ' ')

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
printf "  %-45s %s\n" "Affected vaults (no-expiry RPs):" "$VAULTS_WITH_NOEXPIRY"
echo ""
echo "  ── Phase 2: Backup Items with No Policy ─────"
printf "  %-45s %s\n" "Total items with no policy:" "$PHASE2_COUNT"
printf "  %-45s %s\n" "  VMs (AzureIaasVM):" "$NP_VM_COUNT"
printf "  %-45s %s\n" "  Other (FileShare, SAP, etc.):" "$NP_OTHER_COUNT"
echo ""
echo "  ── Phase 3: RISK — No Policy + No Expiry ────"
printf "  %-45s %s\n" "Items with no policy AND no-expiry RPs:" "$OVERLAP_COUNT"
printf "  %-45s %s\n" "Affected vaults (no-policy + no-expiry):" "$OVERLAP_VAULT_COUNT"
echo ""
echo "  ── RPs older than RP age threshold (report 4, any expiry) ──"
printf "  %-45s %s\n" "Recovery points before ${RP_AGE_CUTOFF}:" "$OLD_RP_COUNT"
echo ""
echo "  ── Phase 4: Vault Classification ─────────────"
printf "  %-45s %s\n" "Clean vaults (not in reports 3, 4, or 7):" "$CLEAN_COUNT"
printf "  %-45s %s\n" "Dirty vaults (overlap, old RPs, and/or timeout):" "$DIRTY_COUNT"
printf "  %-45s %s\n" "Timed-out vaults:" "$TIMEOUT_COUNT"
CLASSIFIED_TOTAL=$((CLEAN_COUNT + DIRTY_COUNT))
printf "  %-45s %s\n" "Coverage (clean + dirty):" "${CLASSIFIED_TOTAL}/${VAULT_COUNT}"
if [[ "$CLASSIFIED_TOTAL" -eq "$VAULT_COUNT" ]]; then
  echo "  ✓  Classification invariant holds."
else
  echo "  ✗  Classification invariant FAILED — investigate CSV integrity."
fi
if [[ "$TIMEOUT_COUNT" -gt 0 ]]; then
  echo "  ⚠  Run status: INCOMPLETE — timed-out vaults forced to dirty/manual review."
else
  echo "  ✓  Run status: COMPLETE (no timed-out vaults)."
fi
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
  echo "  7) $CSV_TIMEOUTS"
else
  echo "  (CSV output disabled — set CSV_OUTPUT=1 to generate files)"
fi
echo ""
echo "  Total execution time: $(format_time $SECONDS)"
echo "============================================="

# Expose this run outputs to the caller when this script is used as a retry child.
if [[ -n "$RETRY_RESULT_META" ]]; then
  {
    echo "RETRY_CHILD_CSV_CLEAN=$CSV_CLEAN"
    echo "RETRY_CHILD_CSV_DIRTY=$CSV_DIRTY"
    echo "RETRY_CHILD_CSV_TIMEOUTS=$CSV_TIMEOUTS"
  } > "$RETRY_RESULT_META"
fi

# -----------------------------------------------------------------------------
# Helper: default second pass for timed-out vaults
# -----------------------------------------------------------------------------
RETRY_META_FILE=""
if [[ "$TIMEOUT_COUNT" -gt 0 && -z "$RETRY_VAULTS_CSV" && "$AUTO_RETRY_TIMEOUTS" == "1" ]]; then
  echo ""
  echo "[*] Helper: starting automatic retry for timed-out vaults..."
  echo "[*] Retry input: $CSV_TIMEOUTS"
  echo "[*] Retry settings: PARALLEL=${AUTO_RETRY_PARALLEL}, VAULT_TIMEOUT=${AUTO_RETRY_TIMEOUT}s"
  echo ""
  RETRY_META_FILE="$TMPDIR_WORK/retry-result-meta.env"
  RETRY_CMD=(
    env
    "RETRY_VAULTS_CSV=$CSV_TIMEOUTS"
    "PARALLEL=$AUTO_RETRY_PARALLEL"
    "VAULT_TIMEOUT=$AUTO_RETRY_TIMEOUT"
    "SKIP_RECENT_HOURS=$SKIP_RECENT_HOURS"
    "RP_AGE_MONTHS=$RP_AGE_MONTHS"
    "CSV_OUTPUT=$CSV_OUTPUT"
    "AUTO_RETRY_TIMEOUTS=0"
    "RETRY_RESULT_META=$RETRY_META_FILE"
    "$0"
  )
  "${RETRY_CMD[@]}"
fi

# -----------------------------------------------------------------------------
# Final authoritative reconciliation (primary runs only)
# -----------------------------------------------------------------------------
if [[ -z "$RETRY_VAULTS_CSV" ]]; then
  RETRY_CLEAN_PATH=""
  RETRY_DIRTY_PATH=""
  RETRY_TIMEOUTS_PATH=""
  if [[ -n "$RETRY_META_FILE" && -f "$RETRY_META_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$RETRY_META_FILE"
    RETRY_CLEAN_PATH="${RETRY_CHILD_CSV_CLEAN:-}"
    RETRY_DIRTY_PATH="${RETRY_CHILD_CSV_DIRTY:-}"
    RETRY_TIMEOUTS_PATH="${RETRY_CHILD_CSV_TIMEOUTS:-}"
  fi

  python3 - "$TMPDIR_WORK/all-vaults.tsv" "$CSV_DIRTY" "$CSV_TIMEOUTS" "$RETRY_DIRTY_PATH" "$RETRY_TIMEOUTS_PATH" "$CSV_FINAL_DIRTY" "$CSV_FINAL_CLEAN" <<'PY'
import csv
import sys

all_vaults_path, base_dirty_path, base_timeout_path, retry_dirty_path, retry_timeout_path, final_dirty_path, final_clean_path = sys.argv[1:8]

def read_dirty_map(path: str):
    out = {}
    if not path:
        return out
    try:
        with open(path, newline="") as f:
            r = csv.reader(f)
            next(r, None)
            for row in r:
                if len(row) < 4:
                    continue
                out[(row[0], row[1], row[2])] = row[3]
    except FileNotFoundError:
        pass
    return out

def read_vault_set(path: str):
    out = set()
    if not path:
        return out
    try:
        with open(path, newline="") as f:
            r = csv.reader(f)
            next(r, None)
            for row in r:
                if len(row) >= 3:
                    out.add((row[0], row[1], row[2]))
    except FileNotFoundError:
        pass
    return out

base_dirty = read_dirty_map(base_dirty_path)
base_timed_out = read_vault_set(base_timeout_path)
retry_dirty = read_dirty_map(retry_dirty_path)
retry_timed_out = read_vault_set(retry_timeout_path)

all_vaults = []
with open(all_vaults_path, newline="") as f:
    r = csv.reader(f, delimiter="\t")
    for row in r:
        if len(row) >= 3:
            all_vaults.append((row[0], row[1], row[2]))

final_dirty = {}
for key in all_vaults:
    if key in base_timed_out:
        if key in retry_timed_out:
            # Retried but still unresolved (or unresolved + risk findings)
            final_dirty[key] = retry_dirty.get(key, "timeout")
        elif key in retry_dirty:
            # Retry succeeded and found real dirty reasons.
            final_dirty[key] = retry_dirty[key]
        else:
            # Retried and no longer dirty -> clean.
            pass
    elif key in base_dirty:
        final_dirty[key] = base_dirty[key]

with open(final_dirty_path, "w", newline="") as df:
    w = csv.writer(df)
    w.writerow(["subscription", "resourceGroup", "vaultName", "reason"])
    for key in sorted(final_dirty):
        w.writerow([key[0], key[1], key[2], final_dirty[key]])

with open(final_clean_path, "w", newline="") as cf:
    w = csv.writer(cf)
    w.writerow(["subscription", "resourceGroup", "vaultName"])
    for key in all_vaults:
        if key not in final_dirty:
            w.writerow([key[0], key[1], key[2]])
PY

  FINAL_DIRTY_COUNT=$(tail -n +2 "$CSV_FINAL_DIRTY" | wc -l | tr -d ' ')
  FINAL_CLEAN_COUNT=$(tail -n +2 "$CSV_FINAL_CLEAN" | wc -l | tr -d ' ')
  FINAL_COVERAGE=$((FINAL_CLEAN_COUNT + FINAL_DIRTY_COUNT))

  echo ""
  echo "============================================="
  echo " FINAL AUTHORITATIVE CLASSIFICATION"
  echo "============================================="
  printf "  %-45s %s\n" "Final clean vaults:" "$FINAL_CLEAN_COUNT"
  printf "  %-45s %s\n" "Final dirty vaults:" "$FINAL_DIRTY_COUNT"
  printf "  %-45s %s\n" "Final coverage (clean + dirty):" "${FINAL_COVERAGE}/${VAULT_COUNT}"
  if [[ "$FINAL_COVERAGE" -eq "$VAULT_COUNT" ]]; then
    echo "  ✓  Final coverage invariant holds."
  else
    echo "  ✗  Final coverage invariant FAILED."
  fi
  if [[ "$CSV_OUTPUT" == "1" ]]; then
    echo "  Final clean file: $CSV_FINAL_CLEAN"
    echo "  Final dirty file: $CSV_FINAL_DIRTY"
  fi
  echo "============================================="
fi
