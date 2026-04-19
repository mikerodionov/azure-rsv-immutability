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

| #   | File                        | Description                                                                                                                                       |
| --- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `no-expiry-rps-*.csv`       | Recovery points with null `expiryTime` (after `SKIP_RECENT_HOURS`)                                                                                |
| 2   | `no-policy-items-*.csv`     | Backup items with no policy assigned                                                                                                              |
| 3   | `no-expiry-no-policy-*.csv` | Items in **both** lists (the real risk)                                                                                                           |
| 4   | `old-rps-*.csv`             | Recovery points whose `recoveryPointTime` is before the RP age cutoff (`RP_AGE_MONTHS`); includes **any** RP (expiry column shows null or a date) |
| 5   | `clean-vaults-*.csv`        | Vaults not appearing in reports 3 or 4                                                                                                            |
| 6   | `dirty-vaults-*.csv`        | Vaults appearing in report 3 or 4 (with reason)                                                                                                   |

### Clean vs dirty vaults

**Report 1** lists only recovery points **without** an expiry (`expiryTime` null), optionally skipping the last `SKIP_RECENT_HOURS`. **Report 4** lists recovery points **older than `RP_AGE_MONTHS`** by `recoveryPointTime`, **whether or not** they have retention expiry — this drives the “retention / hygiene” bucket for vault locking.

**Dirty** — a vault in **`dirty-vaults-*.csv`** if **either**:

1. **Report 3** (`no-expiry-no-policy-*.csv`): at least one item **has no policy** and still has **no-expiry** RPs in report 1 (overlap).
2. **Report 4** (`old-rps-*.csv`): at least one recovery point (any expiry) is **older than** the configured age threshold.

**Clean** — vault appears only in **`clean-vaults-*.csv`**: no rows from report 3 or 4.

The **`reason`** column on dirty vaults is `no-policy-no-expiry`, `old-rps`, or **both**.

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

# summary only, no CSV files
CSV_OUTPUT=0 ./scripts/rsv-immutability-readiness-check.sh

# 15 minute timeout per vault (default 10 min)
VAULT_TIMEOUT=900 ./scripts/rsv-immutability-readiness-check.sh
```

### Environment Variables

| Variable            | Default | Description                                                                  |
| ------------------- | ------- | ---------------------------------------------------------------------------- |
| `PARALLEL`          | `10`    | Parallel vault workers (raising this often worsens Azure API throttling)     |
| `SKIP_RECENT_HOURS` | `48`    | Skip no-expiry RPs newer than this in **report 1** (set `0` to include all)  |
| `RP_AGE_MONTHS`     | `13`    | Recovery points older than this appear in **report 4** and mark vaults dirty |
| `CSV_OUTPUT`        | `1`     | Set `0` to disable CSV file generation (summary only)                        |
| `VAULT_TIMEOUT`     | `600`   | Seconds before a stuck vault worker is killed (10 min)                       |
| `DEBUG`             | `0`     | Enable verbose debug logging (`1` to enable)                                 |
| `DEBUG_MAX`         | `3`     | Max vaults to process in debug mode                                          |

### Prerequisites

- Azure CLI (`az`) authenticated with access to target subscriptions
- `jq` for JSON processing
- Python 3 (`python3`) — CSV joins and clean/dirty vault reports (RFC-safe parsing)
- Bash 4+ (parallel worker bookkeeping uses associative arrays)
