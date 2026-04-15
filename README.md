# azure-rsv-immutability

## RSV Immutability Readiness Check Script

Scans all Recovery Services Vaults across subscriptions and produces 4 CSV reports + a summary table to assess readiness for vault-level immutability locking.

### Repository Structure

```
├── scripts/
│   └── rsv-immutability-readiness-check.sh   # main script
├── reports/                                  # CSV output (git-ignored)
│   └── .gitkeep
├── .gitignore
└── README.md
```

CSV reports are written to `reports/` and are git-ignored so they never get committed back.

### Output Files (timestamped)

| # | File                        | Description                                           |
|---|-----------------------------|-------------------------------------------------------|
| 1 | `no-expiry-rps-*.csv`       | Recovery points with no expiry date                   |
| 2 | `no-policy-items-*.csv`     | Backup items with no policy assigned                  |
| 3 | `no-expiry-no-policy-*.csv` | Items in **both** lists (the real risk)               |
| 4 | `old-no-expiry-rps-*.csv`   | No-expiry RPs older than `RP_AGE_MONTHS` (default 13) |

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
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PARALLEL` | `10` | Number of parallel vault workers |
| `SKIP_RECENT_HOURS` | `48` | Skip no-expiry RPs newer than this (set `0` to include all) |
| `RP_AGE_MONTHS` | `13` | Threshold for the "old RPs" report (CSV #4) |
| `DEBUG` | `0` | Enable verbose debug logging (`1` to enable) |
| `DEBUG_MAX` | `3` | Max vaults to process in debug mode |

### Prerequisites

- Azure CLI (`az`) authenticated with access to target subscriptions
- `jq` for JSON processing
- Bash 4+ (for associative arrays)
