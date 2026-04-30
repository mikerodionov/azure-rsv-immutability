# azure-rsv-immutability

## RSV Immutability Readiness Check (Go)

Scans all Recovery Services Vaults across subscriptions and produces CSV reports, a clean vault list, and a summary table to assess readiness for vault-level immutability locking.

### Repository Structure

```text
├── cmd/
│   └── rsv-immutability-readiness/ # main Go CLI
├── go.mod                          # Go module definition
├── .gitignore
└── README.md
```

CSV reports are written to `../rsv-reports/` (one level above the repo) so they are never at risk of being lost during git operations.

### Phase Logic

The tool runs in **4 sequential phases**, each building on the previous. All data collection happens in phases 1-2; phases 3-4 are pure post-processing.

#### Phase 1 — Recovery Point Scanning (per-vault, parallel)

Discovers all RSV vaults via Azure Resource Graph, then scans each vault in parallel using `az backup item list` + `az backup recoverypoint list`:

1. **Items**: fetches all backup items from the vault via backup management API.
2. **Soft-delete filter**: items with `isScheduledForDeferredDelete=true` are captured in **report 15** and **skipped from RP enumeration** (optimization + semantics — these are already being destroyed by Azure). Note: the backup API (`az backup item list`) does **not** return items in `SoftDeleted` state at all — those are only visible via ARG and are handled in phase 2.
3. **RP enumeration**: for each remaining item, enumerates recovery points via `az backup recoverypoint list`.
4. **No-expiry detection**: RPs with null `expiryTime` (after `SKIP_RECENT_HOURS` filter) → **report 1**. For each, inferred expiry is calculated as `recoveryPointTime + policy retention days`. If the vault's policy can be resolved, uses actual retention (`RSV_Assigned_Policy`); otherwise falls back to `ASSUMED_MAX_RETENTION_DAYS` (`Assumed_Max_Retention`). Inferred-expiry RPs are split into **report 13** (already elapsed) and **report 14** (not yet elapsed). Items with `protectionState` in `INFERRED_EXCLUDE_STATES` (default `SoftDeleted`) are excluded from reports 13/14.
5. **Old-RP detection**: RPs older than `RP_AGE_MONTHS` (regardless of expiry) → **report 4**.
6. **Timeout handling**: vaults that exceed `VAULT_TIMEOUT` are killed → **report 7** (treated as dirty).

**Produces**: reports 1, 4, 7, 13, 14, 15.

#### Phase 2 — No-Policy Item Discovery (tenant-wide ARG)

Queries Azure Resource Graph for backup items with no policy assigned (`policyId` and `policyName` both empty). The ARG query excludes:

- `protectionState == 'SoftDeleted'` — items already in soft-delete lifecycle
- `isScheduledForDeferredDelete == true` — items with active deferred-delete countdown

Additionally queries ARG for all soft-deleted items (`protectionState == 'SoftDeleted'` or `isScheduledForDeferredDelete == true`) and writes them to **report 15** for audit visibility. This is the authoritative source for report 15 since the backup API does not return soft-deleted items.

Remaining items (all `ProtectionStopped` in practice) → **report 2**, with state distribution → **report 11**.

**Produces**: reports 2, 11, 15.

#### Phase 3 — Cross-Reference (offline join)

Joins report 1 (no-expiry RPs) with report 2 (no-policy items) by vault+item name. Items that appear in **both** — no policy AND no-expiry RPs — are the real immutability risk → **report 3**, with state distribution → **report 12**.

**Produces**: reports 3, 12.

#### Phase 4 — Vault Classification (offline)

Classifies each vault as clean or dirty based on presence in reports 3, 4, and 7:

| Dirty reason          | Source   | Meaning                                        |
| --------------------- | -------- | ---------------------------------------------- |
| `no-policy-no-expiry` | Report 3 | Item has no policy AND has no-expiry RPs       |
| `old-rps`             | Report 4 | Has recovery points older than `RP_AGE_MONTHS` |
| `timeout`             | Report 7 | Vault scan timed out — forced to manual review |

Vaults with **any** dirty reason → **report 6**. Vaults with **no** dirty reasons → **report 5**. Item-level detail for dirty vaults → **report 10**. Plain-text clean vault names → **clean-vaults-*.list**.

If auto-retry is enabled and timeouts occurred, the full 4-phase cycle is re-run for timed-out vaults only. Final reconciliation merges results → **reports 8** (final clean) and **9** (final dirty).

**Produces**: reports 5, 6, 8, 9, 10, clean-vaults list.

#### Protection States

The tool observes these backup item states (Azure naming varies between backup API and ARG):

| Backup API state    | ARG state              | Meaning                                                     | Handling                                                        |
| ------------------- | ---------------------- | ----------------------------------------------------------- | --------------------------------------------------------------- |
| `Protected`         | `ProtectionConfigured` | Active backup, policy attached                              | Normal — RPs enumerated, included in all reports                |
| `BackupsSuspended`  | `BackupsSuspended`     | Policy attached but execution paused                        | RPs enumerated, included in all reports                         |
| `ProtectionStopped` | `ProtectionStopped`    | "Stop backup with retain data" — policy detached            | RPs enumerated. **Primary source of orphan RPs**                |
| *(not returned)*    | `SoftDeleted`          | "Delete backup data" executed, soft-delete countdown active | Excluded from reports 1-4, 13-14. Captured in report 15 via ARG |

Items in `SoftDeleted` state are **not returned** by `az backup item list` — they only appear in Azure Resource Graph. The tool captures them in report 15 via a dedicated ARG query in phase 2 for audit purposes.

### Output Files (timestamped)

All CSVs are written on-the-fly so partial data survives crashes:

- `1-no-expiry-rps-*.csv` — Recovery points with null `expiryTime` (after `SKIP_RECENT_HOURS`) *(Phase 1)*
- `2-no-policy-items-*.csv` — Backup items with no policy assigned *(Phase 2)*
- `3-no-expiry-no-policy-*.csv` — Items in **both** lists (the real risk) *(Phase 3)*
- `4-old-rps-*.csv` — Recovery points whose `recoveryPointTime` is before the RP age cutoff (`RP_AGE_MONTHS`); includes **any** RP (expiry column shows null or date) *(Phase 1)*
- `5-clean-vaults-*.csv` — Vaults not appearing in reports 3, 4, or 7 *(Phase 4)*
- `6-dirty-vaults-*.csv` — Vaults appearing in report 3, report 4, or timeout report (with reason) *(Phase 4)*
- `7-timed-out-vaults-*.csv` — Vault workers killed after `VAULT_TIMEOUT`; treated as `dirty` with reason `timeout` *(Phase 1)*
- `8-final-clean-vaults-*.csv` — Final authoritative clean list after timeout retry reconciliation *(Phase 4 + retry)*
- `9-final-dirty-vaults-*.csv` — Final authoritative dirty list after timeout retry reconciliation *(Phase 4 + retry)*
- `10-dirty-items-detail-*.csv` — Item-level detail for every dirty vault: offending items/RPs with reason, RP time, type, and expiry (for review) *(Phase 4)*
- `11-no-policy-protectionstate-distribution-*.csv` — `protectionState` distribution for all no-policy items *(Phase 2)*
- `12-overlap-protectionstate-distribution-*.csv` — `protectionState` distribution for overlap subset (no-policy + no-expiry) *(Phase 3)*
- `13-inferred-expiry-passed-*.csv` — Null-expiry RPs where inferred expiry is already elapsed (includes `protectionState`, `inferenceBase`, `retentionDays`) *(Phase 1)*
- `14-inferred-expiry-not-passed-*.csv` — Null-expiry RPs where inferred expiry has not elapsed yet (includes `protectionState`, `inferenceBase`, `retentionDays`) *(Phase 1)*
- `15-soft-deleted-items-*.csv` — Backup items in soft-delete lifecycle (`SoftDeleted` / `isScheduledForDeferredDelete`), queried from ARG. These are excluded from RP enumeration and all risk reports — captured for audit only *(Phase 2)*
- `clean-vaults-*.list` — Plain text list of clean vault names (one per line, no header) for use as input to bulk operations (e.g. immutability-management workflow whitelist) *(Phase 4)*

### Clean vs dirty vaults

The tool classifies every scanned vault as **clean** or **dirty** based on whether it poses a risk for immutability locking.

#### Clean vault

A vault is **clean** (`clean-vaults-*.csv`) when it has **zero** rows in reports 3, 4, and 7 — meaning:

- No orphaned items: every backup item either has a policy attached or has no null-expiry recovery points.
- No stale RPs: no recovery point is older than the configured age threshold (`RP_AGE_MONTHS`, default 13 months).
- Scan completed: the vault did not time out.

**Clean vaults are safe to lock for immutability** provided you review report 1 for the vault — a clean vault can still have no-expiry RPs if those items have a policy attached (they pass report 3 but could be “Retain forever” items that become permanently undeletable after locking).

Soft-deleted items (report 15) are excluded by design — they auto-purge after the retention countdown and are not a lock risk.

#### Dirty vault

A vault is **dirty** (`dirty-vaults-*.csv`) if **any** of:

| Dirty reason          | Source   | Meaning                                    | Ops action required                                                                                                                                                                                                               |
| --------------------- | -------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `no-policy-no-expiry` | Report 3 | Item has no policy AND has null-expiry RPs | **Delete backup data** (`az backup item delete --delete-backup-data`) or re-attach a finite-retention policy. Most likely cause: “Stop backup with retain data” was used but nobody clicked “Delete data” — backups are orphaned. |
| `old-rps`             | Report 4 | RP older than `RP_AGE_MONTHS` threshold    | Review old RPs. If policy has finite retention they should auto-expire; if “retain forever”, manually delete or change policy.                                                                                                    |
| `timeout`             | Report 7 | Vault scan timed out                       | Re-run with longer `VAULT_TIMEOUT` or manually inspect.                                                                                                                                                                           |

The `reason` column on dirty vaults includes one or more of: `no-policy-no-expiry`, `old-rps`, `timeout`.

Use **report 10** (`dirty-items-detail-*.csv`) to get per-item detail for handing to ops teams.

When auto retry runs, the tool keeps first-pass and retry artifacts intact, then emits **final** clean/dirty CSVs where previously timed-out vaults are reclassified from retry outcomes.

### Why skip recent hours?

Default **`SKIP_RECENT_HOURS=48`** drops brand-new no-expiry recovery points from **report 1** so runs are less noisy. It does **not** filter report 4 (age vs `recoveryPointTime` uses **`RP_AGE_MONTHS`** only). Use **`SKIP_RECENT_HOURS=0`** when you need every no-expiry RP in report 1.

### Usage

Current status:

- full 4-phase implementation with Azure CLI calls
- parallel per-vault processing with timeout handling
- same CSV contracts and final reconciliation logic (including auto retry)
- retry writes to temp dir (cleaned up automatically) — only one set of output files per run
- added inferred-expiry analysis for null-expiry RPs with explicit inference source (`RSV_Assigned_Policy` / `Assumed_Max_Retention`)

Run it:

```bash
# default mode (fast): immutability state summary + cached clean-vault summary
go run ./cmd/rsv-immutability-readiness

# same as default
go run ./cmd/rsv-immutability-readiness --report

# full long-running 4-phase scan (generates fresh CSVs)
go run ./cmd/rsv-immutability-readiness --scan
```

Report mode cache behavior:

- Cached clean-vault summary is accepted only when all artifacts exist for the same timestamp:
  - `8-final-clean-vaults-<timestamp>.csv`
  - `9-final-dirty-vaults-<timestamp>.csv`
  - `clean-vaults-<timestamp>.list`
- Validation rules for cached summary:
  - both final CSV headers must match expected schema
  - final clean CSV must contain at least one vault row
  - clean list must be non-empty
  - clean list row count must match final clean CSV row count (header-like first line in list is tolerated)
- If any check fails, report mode treats this as no cache and prints: run with `--scan`.

Scan mode empty-environment behavior:

- If phase 1 discovers zero Recovery Services Vaults, scan mode stops early, prints an explicit message, and removes generated artifacts for that run timestamp.

Examples:

```bash
# include all RPs regardless of age (scan mode)
SKIP_RECENT_HOURS=0 go run ./cmd/rsv-immutability-readiness --scan

# 5 parallel vault workers (scan mode)
PARALLEL=5 go run ./cmd/rsv-immutability-readiness --scan

# debug mode — 3 vaults max, verbose logging (scan mode)
DEBUG=1 go run ./cmd/rsv-immutability-readiness --scan

# debug 1 vault only
DEBUG=1 DEBUG_MAX=1 go run ./cmd/rsv-immutability-readiness --scan

# set old RP threshold to 6 months instead of default 13
RP_AGE_MONTHS=6 go run ./cmd/rsv-immutability-readiness --scan

# summary only, no CSV files
CSV_OUTPUT=0 go run ./cmd/rsv-immutability-readiness --scan

# 15 minute timeout per vault (default 10 min)
VAULT_TIMEOUT=900 go run ./cmd/rsv-immutability-readiness --scan

# retry only previously timed-out vaults (recommended second pass)
RETRY_VAULTS_CSV=../rsv-reports/7-timed-out-vaults-YYYYMMDD-HHMMSS.csv PARALLEL=5 VAULT_TIMEOUT=1200 go run ./cmd/rsv-immutability-readiness --scan

# default behavior: auto-runs one retry pass when timeouts are detected
AUTO_RETRY_TIMEOUTS=1 go run ./cmd/rsv-immutability-readiness --scan

# tune automatic retry settings
AUTO_RETRY_TIMEOUTS=1 AUTO_RETRY_PARALLEL=4 AUTO_RETRY_TIMEOUT=1800 go run ./cmd/rsv-immutability-readiness --scan
```

### Environment Variables

- `PARALLEL` (default `10`) — Parallel vault workers (raising this often worsens Azure API throttling)
- `SKIP_RECENT_HOURS` (default `48`) — Skip no-expiry RPs newer than this in **report 1** (set `0` to include all)
- `RP_AGE_MONTHS` (default `13`) — Recovery points older than this appear in **report 4** and mark vaults dirty
- `CSV_OUTPUT` (default `1`) — Set `0` to disable CSV file generation (summary only)
- `VAULT_TIMEOUT` (default `600`) — Seconds before a stuck vault worker is killed (10 min)
- `RETRY_VAULTS_CSV` (default empty) — Optional CSV path (`subscription,resourceGroup,vaultName`) to scan only the listed vaults
- `AUTO_RETRY_TIMEOUTS` (default `1`) — If first pass has timeouts and this is not already a retry run, auto-run one retry pass
- `AUTO_RETRY_PARALLEL` (default `5`) — Parallel workers for auto retry pass
- `AUTO_RETRY_TIMEOUT` (default `1200`) — Per-vault timeout seconds for auto retry pass
- `DEBUG` (default `0`) — Enable verbose debug logging (`1` to enable)
- `DEBUG_MAX` (default `3`) — Max vaults to process in debug mode
- `DEBUG_PAGING` (default `0`) — Enable vault-discovery paging diagnostics in logs
- `REPORT_DIR` (default `../rsv-reports/`) — Directory for output files
- `REPORT_TIME_MODE` (default `date`) — Output timestamp format in CSVs: `date` (`YYYY-MM-DD`) or `datetime` (`YYYY-MM-DD HH:MM:SS UTC`)
- `ASSUMED_MAX_RETENTION_DAYS` (default `3650`) — Fallback retention used for inferred-expiry reports when assigned policy retention cannot be resolved (`3650` = 10 years, chosen as conservative upper-bound assumption)
- `INFERRED_EXCLUDE_STATES` (default `SoftDeleted`) — Comma-separated backup item protection states to exclude from inferred-expiry reports (example: `SoftDeleted,BackupStopped`)

### Soft-delete handling

Backup items in the soft-delete lifecycle are handled at two levels:

1. **Phase 1 (backup API)**: Items with `isScheduledForDeferredDelete=true` are skipped from RP enumeration (belt-and-suspenders — in practice `az backup item list` does not return `SoftDeleted` items at all).
2. **Phase 2 (ARG)**: A dedicated ARG query captures all items with `protectionState == 'SoftDeleted'` or `isScheduledForDeferredDelete == true` and writes them to report 15 for audit. The no-policy query separately excludes both states to keep them out of report 2.

Items in `SoftDeleted` state are only visible in Azure Resource Graph, not in the backup management API. Once the soft-delete retention period expires, items disappear from both APIs entirely — there is no "completed soft delete" state.

### RSV Behavioral Assumptions

This section documents observed Azure Recovery Services Vault behaviors that this tool relies on for its classification logic. These are based on testing, API observation, and available documentation. **None of these are guaranteed by Azure SLA** — validate against your own environment before making operational decisions.

#### 1. Recovery points carry an internal expiry tag not exposed via API

Every recovery point is tagged with an intended expiration date on the service side at creation time, derived from the backup policy retention settings. However, this internal tag is **not always surfaced** in the portal or `az backup recoverypoint list` API — the `expiryTime` property frequently returns `null`.

Known cases where `expiryTime` is null:
- **Recent RPs (< 24-48h old)**: The expiry metadata is stamped asynchronously by a background GC/hardening process. Until a superseding RP is created and hardened, the latest 1-2 RPs show null expiry. Documented: [Azure Backup FAQ — Why the expiry time for latest recovery points doesn't appear](https://learn.microsoft.com/en-us/azure/backup/backup-azure-vm-backup-faq#why-the-expiry-time-for-latest-recovery-points-doesn-t-appear-in-the-azure-portal-for-vms).
- **LTR recovery points**: Weekly, monthly, and yearly retention RPs consistently show null `expiryTime`. Retention for these appears to be managed internally by policy-based count/time rules rather than an explicit per-RP expiry timestamp.

**Tool implication**: `SKIP_RECENT_HOURS` (default 48) filters out the first case. The second case is why the tool infers expiry from policy retention settings (reports 13/14) rather than relying solely on the API-reported `expiryTime`.

#### 2. "Retain forever" adds a GC-ignore flag, not infinite retention

When "Stop protection → Retain backup data (forever)" is selected, the existing RPs keep their original policy-based internal expiry tags. The "retain forever" option adds a **garbage-collection ignore flag** that prevents automatic cleanup — but it does **not** remove or override the internal expiry.

Consequence: after the internal expiry passes, **manual deletion still works** — even on a locked immutable vault. The operational challenge is knowing *when* the internal expiry passes, since it is not visible via API. It must be derived from the original policy's retention period at the time protection was stopped.

**Tool implication**: This is why the tool computes inferred expiry (`recoveryPointTime + policy retention days`) and classifies items where this inferred expiry has already passed (report 13) separately from those where it hasn't (report 14).

#### 3. Immutability blocks deletion of pre-existing stopped/retained RPs

Enabling immutability on a vault **retroactively affects** all existing recovery points, including those from items where protection was already stopped with "retain data" before immutability was enabled. Deletion of these RPs is blocked until their internal expiry passes, same as for RPs created after immutability was enabled.

This was confirmed through testing — it contradicts the intuition that pre-immutability items would be grandfathered in.

Ref: [Immutable vault — restricted operations](https://learn.microsoft.com/en-us/azure/backup/backup-azure-immutable-vault-how-to-manage?tabs=recovery-services-vault#perform-restricted-operations).

#### 4. "Retain as per policy" option only exists on immutable vaults

The "Stop protection" dialog offers two retention sub-options **only when immutability is enabled** (locked or unlocked):
- **Retain forever** — adds the GC-ignore flag (assumption 2)
- **Retain as per policy** — retains RPs according to the attached policy's retention schedule

On non-immutable vaults, "Stop with retain data" implicitly means "retain forever" — there is no sub-option.

**Governance gap**: Even on immutable vaults, there is no way to block the "Retain forever" option via Azure Policy or RBAC. Operators can still select it, creating no-expiry RPs that must be tracked manually. Consider enforcing this via organizational policy/training.

#### 5. The last recovery point is never automatically deleted

For any backup item, Azure never automatically removes the last remaining recovery point — regardless of policy retention settings or expiry. It must be manually deleted via `az backup protection disable --delete-backup-data`.

This means that even after all policy-driven RPs expire naturally (e.g., post-VM decommission), one RP will always remain and must be cleaned up as an operational step.

**Tool implication**: Items in `ProtectionStopped` state with a single remaining RP are expected and common — they appear in report 10 as actionable cleanup candidates.

#### 6. "Oldest restore point" is a portal-only property

The "Oldest restore point" date shown in the Azure portal for backup items is a GUI-only computation. There is no REST API or CLI command to retrieve this value directly — it is derived from existing queries internally by the portal.

**Tool implication**: The tool enumerates all RPs via `az backup recoverypoint list` and derives age metrics directly, which is the only reliable method available via automation.

#### 7. Soft-deleted items are invisible to the backup management API

Items in `SoftDeleted` state (after "Delete backup data" is executed, during the soft-delete retention countdown) are **not returned** by `az backup item list`. They are only visible via Azure Resource Graph queries on `recoveryservicesresources`.

Once the soft-delete retention period expires, the item disappears from both APIs entirely — there is no "completed soft delete" state.

**Tool implication**: Report 15 uses a dedicated ARG query to capture soft-deleted items. They are excluded from risk reports (1-4, 13-14) since they are already in a destruction lifecycle.

#### 8. No per-recovery-point delete API exists

Azure does not expose an API to delete individual recovery points from a backup item. The only deletion path is `az backup protection disable --delete-backup-data`, which removes **all** recovery points for the item. For actively `Protected` items, this destroys current backups — making it unsuitable for cleaning up individual old RPs on production workloads.

**Tool implication**: Report 10 separates `ProtectionStopped`/`BackupsSuspended` items (cleanable via `--delete-backup-data` without risk) from `Protected` items (blocked — would destroy active backups). The 147-item "blocked" category in a typical scan requires a different remediation path (e.g., wait for natural expiry, or open a support case).

### Prerequisites

- Go 1.22+ (for local run/build)
- Azure CLI (`az`) authenticated with access to target subscriptions
- Azure CLI extension `resource-graph` (the tool auto-installs it if missing)