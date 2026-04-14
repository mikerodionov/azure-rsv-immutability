# azure-rsv-immutability

## RSV Immutability Readiness Check Script

Produces 3 CSVs + summary table to assess readiness for vault locking.

Output files (timestamped):
  1) no-expiry-rps-YYYYMMDD-HHMMSS.csv       — Recovery points with no expiry
  2) no-policy-items-YYYYMMDD-HHMMSS.csv     — Backup items with no policy
  3) no-expiry-no-policy-YYYYMMDD-HHMMSS.csv — Items in BOTH (the real risk)

Usage examples:

```basg
./rsv-immutability-readiness-check.sh                     # default (10 parallel, skip last 48h)
SKIP_RECENT_HOURS=0 ./rsv-immutability-readiness-check.sh # include all RPs
PARALLEL=5 ./rsv-immutability-readiness-check.sh          # 5 parallel vaults
DEBUG=1 ./rsv-immutability-readiness-check.sh             # debug (3 vaults, verbose)
DEBUG=1 DEBUG_MAX=1 ./rsv-immutability-readiness-check.sh # debug 1 vault
```
