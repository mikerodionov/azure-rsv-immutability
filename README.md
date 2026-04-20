# azure-rsv-immutability

## RSV Immutability Readiness Check Script

Scans all Recovery Services Vaults across subscriptions and produces up to 9 CSV reports + a summary table to assess readiness for vault-level immutability locking.

### Repository Structure

```text
├── scripts/
│   └── rsv-immutability-readiness-check.sh   # main script
├── .gitignore
└── README.md
```

CSV reports are written to `../rsv-reports/` (one level above the repo) so they are never at risk of being lost during git operations.

### Output Files (timestamped)

All CSVs are written on-the-fly so partial data survives crashes. Reports 1-2 are the raw data collected in Phase 1 and 2, reports 3-9 are derived from them:

- `1-no-expiry-rps-*.csv` — Recovery points with null `expiryTime` (after `SKIP_RECENT_HOURS`)
- `2-no-policy-items-*.csv` — Backup items with no policy assigned
- `3-no-expiry-no-policy-*.csv` — Items in **both** lists (the real risk)
- `4-old-rps-*.csv` — Backup items whose oldest recovery point is before the RP age cutoff (`RP_AGE_MONTHS`); default source is item metadata (`oldestRecoveryPoint`)
- `5-clean-vaults-*.csv` — Vaults not appearing in reports 3, 4, or 7
- `6-dirty-vaults-*.csv` — Vaults appearing in report 3, report 4, or timeout report (with reason)
- `7-timed-out-vaults-*.csv` — Vault workers killed after `VAULT_TIMEOUT`; treated as `dirty` with reason `timeout`
- `8-final-clean-vaults-*.csv` — Final authoritative clean list after timeout retry reconciliation
- `9-final-dirty-vaults-*.csv` — Final authoritative dirty list after timeout retry reconciliation

### Clean vs dirty vaults

**Report 1** lists only recovery points **without** an expiry (`expiryTime` null), optionally skipping the last `SKIP_RECENT_HOURS`. **Report 4** (default mode) flags backup items where item metadata indicates the oldest RP is older than `RP_AGE_MONTHS`; this drives the “retention / hygiene” bucket for vault locking.

**Dirty** — a vault in **`dirty-vaults-*.csv`** if **any**:

1. **Report 3** (`3-no-expiry-no-policy-*.csv`): at least one item **has no policy** and still has **no-expiry** RPs in report 1 (overlap).
2. **Report 4** (`4-old-rps-*.csv`): at least one recovery point (any expiry) is **older than** the configured age threshold.
3. **Report 7** (`7-timed-out-vaults-*.csv`): vault scan timed out and is forced to manual review (`timeout` reason).

**Clean** — vault appears only in **`clean-vaults-*.csv`**: no rows from report 3, 4, or 7.

The **`reason`** column on dirty vaults includes `no-policy-no-expiry`, `old-rps`, `timeout`, or combinations.

When auto retry runs, the script keeps first-pass and retry artifacts intact, then emits **final** clean/dirty CSVs where previously timed-out vaults are reclassified from retry outcomes.

### Why skip recent hours?

Default **`SKIP_RECENT_HOURS=48`** drops brand-new no-expiry recovery points from **report 1** so runs are less noisy. It does **not** filter report 4 (age vs `recoveryPointTime` uses **`RP_AGE_MONTHS`** only). Use **`SKIP_RECENT_HOURS=0`** when you need every no-expiry RP in report 1.

### Usage

```bash
# default — 10 parallel workers, skip RPs newer than 48h, old RP threshold 13 months
./scripts/rsv-immutability-readiness-check.sh

# include all RPs regardless of age
SKIP_RECENT_HOURS=0 ./scripts/rsv-immutability-readiness-check.sh

# 5 parallel vault workers
PARALLEL=5 ./scripts/rsv-immutability-readiness-check.sh

# debug mode — 3 vaults max, verbose logging
DEBUG=1 ./scripts/rsv-immutability-readiness-check.sh

# debug 1 vault only
DEBUG=1 DEBUG_MAX=1 ./scripts/rsv-immutability-readiness-check.sh

# set old RP threshold to 6 months instead of default 13
RP_AGE_MONTHS=6 ./scripts/rsv-immutability-readiness-check.sh

# legacy mode: derive old RPs by scanning all recovery points (slower)
OLD_RPS_SOURCE=rp-scan ./scripts/rsv-immutability-readiness-check.sh

# summary only, no CSV files
CSV_OUTPUT=0 ./scripts/rsv-immutability-readiness-check.sh

# 15 minute timeout per vault (default 10 min)
VAULT_TIMEOUT=900 ./scripts/rsv-immutability-readiness-check.sh

# retry only previously timed-out vaults (recommended second pass)
RETRY_VAULTS_CSV=../rsv-reports/7-timed-out-vaults-YYYYMMDD-HHMMSS.csv PARALLEL=5 VAULT_TIMEOUT=1200 ./scripts/rsv-immutability-readiness-check.sh

# default behavior: auto-runs one retry pass when timeouts are detected
AUTO_RETRY_TIMEOUTS=1 ./scripts/rsv-immutability-readiness-check.sh

# tune automatic retry settings
AUTO_RETRY_TIMEOUTS=1 AUTO_RETRY_PARALLEL=4 AUTO_RETRY_TIMEOUT=1800 ./scripts/rsv-immutability-readiness-check.sh
```

### Environment Variables

- `PARALLEL` (default `10`) — Parallel vault workers (raising this often worsens Azure API throttling)
- `SKIP_RECENT_HOURS` (default `48`) — Skip no-expiry RPs newer than this in **report 1** (set `0` to include all)
- `RP_AGE_MONTHS` (default `13`) — Recovery points older than this appear in **report 4** and mark vaults dirty
- `OLD_RPS_SOURCE` (default `item-oldest`) — Source for report 4 age detection: `item-oldest` (faster) or `rp-scan` (legacy, slower)
- `CSV_OUTPUT` (default `1`) — Set `0` to disable CSV file generation (summary only)
- `VAULT_TIMEOUT` (default `600`) — Seconds before a stuck vault worker is killed (10 min)
- `RETRY_VAULTS_CSV` (default empty) — Optional CSV path (`subscription,resourceGroup,vaultName`) to scan only the listed vaults
- `AUTO_RETRY_TIMEOUTS` (default `1`) — If first pass has timeouts and this is not already a retry run, auto-run one retry pass
- `AUTO_RETRY_PARALLEL` (default `5`) — Parallel workers for auto retry pass
- `AUTO_RETRY_TIMEOUT` (default `1200`) — Per-vault timeout seconds for auto retry pass
- `DEBUG` (default `0`) — Enable verbose debug logging (`1` to enable)
- `DEBUG_MAX` (default `3`) — Max vaults to process in debug mode

### Prerequisites

- Azure CLI (`az`) authenticated with access to target subscriptions
- `jq` for JSON processing
- Python 3 (`python3`) — CSV joins and clean/dirty vault reports (RFC-safe parsing)
- Bash 4+ (parallel worker bookkeeping uses associative arrays)
