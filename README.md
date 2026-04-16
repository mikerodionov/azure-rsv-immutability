# azure-rsv-immutability

## RSV Immutability Readiness Check Script

Scans all Recovery Services Vaults across subscriptions and produces up to 6 CSV reports + a summary table to assess readiness for vault-level immutability locking.

### Repository Structure

```
├── scripts/
│   └── rsv-immutability-readiness-check.sh   # main script
├── .gitignore
└── README.md
```

CSV reports are written to `../rsv-reports/` (one level above the repo) so they are never at risk of being lost during git operations.

### Output Files (timestamped)

All CSVs are written on-the-fly so partial data survives crashes. Reports 1–2 are the raw data collected in Phase 1 and 2, reports 3–6 are derived from them:

| # | File                        | Description                                           |
|---|-----------------------------|-------------------------------------------------------|
| 1 | `no-expiry-rps-*.csv`       | All recovery points with no expiry date               |
| 2 | `no-policy-items-*.csv`     | Backup items with no policy assigned                  |
| 3 | `no-expiry-no-policy-*.csv` | Items in **both** lists (the real risk)               |
| 4 | `old-no-expiry-rps-*.csv`   | No-expiry RPs older than `RP_AGE_MONTHS` (default 13) |
| 5 | `clean-vaults-*.csv`        | Vaults not appearing in reports 3 or 4                |
| 6 | `dirty-vaults-*.csv`        | Vaults appearing in report 3 or 4 (with reason)      |

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

# summary only, no CSV files
CSV_OUTPUT=0 ./scripts/rsv-immutability-readiness-check.sh

# 15 minute timeout per vault (default 10 min)
VAULT_TIMEOUT=900 ./scripts/rsv-immutability-readiness-check.sh
```

### Environment Variables

| Variable            | Default | Description                                                 |
|---------------------|---------|-------------------------------------------------------------|
| `PARALLEL`          | `10`    | Number of parallel vault workers                            |
| `SKIP_RECENT_HOURS` | `48`    | Skip no-expiry RPs newer than this (set `0` to include all) |
| `RP_AGE_MONTHS`     | `13`    | Threshold for the "old RPs" report (CSV #4)                 |
| `CSV_OUTPUT`        | `1`     | Set `0` to disable CSV file generation (summary only)       |
| `VAULT_TIMEOUT`     | `600`   | Seconds before a stuck vault worker is killed (10 min)      |
| `DEBUG`             | `0`     | Enable verbose debug logging (`1` to enable)                |
| `DEBUG_MAX`         | `3`     | Max vaults to process in debug mode                         |

### Prerequisites

- Azure CLI (`az`) authenticated with access to target subscriptions
- `jq` for JSON processing
- Bash 4+ (for associative arrays)
