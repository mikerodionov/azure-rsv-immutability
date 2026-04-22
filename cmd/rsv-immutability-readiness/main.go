package main

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	Debug             bool
	DebugPaging       bool
	DebugMax          int
	Parallel          int
	SkipRecentHours   int
	RPAgeMonths       int
	CSVOutput         bool
	VaultTimeout      time.Duration
	RetryVaultsCSV    string
	AutoRetryTimeouts bool
	AutoRetryParallel int
	AutoRetryTimeout  time.Duration
	OutputTimeMode    string
	ReportDir         string
	TS                string
}

type VaultInfo struct {
	Subscription  string
	ResourceGroup string
	VaultName     string
}

type FullStats struct {
	VaultCount      int
	NoExpiryCount   int64
	OldRPCount      int64
	NoPolicyCount   int64
	NoPolicyVMCount int64
	OverlapCount    int64
	CleanCount      int64
	DirtyCount      int64
	TimeoutCount    int64
	FinalCleanCount int64
	FinalDirtyCount int64
}

type RunContext struct {
	Config    Config
	CSV       map[string]string
	AllVaults []VaultInfo
	TimedOut  map[string]VaultInfo
	Stats     FullStats
}

// Entrypoint and high-level orchestration.
func main() {
	if err := runFull(); err != nil {
		log.Fatalf("[!] %v", err)
	}
}

func runFull() error {
	start := time.Now()
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("config error: %w", err)
	}
	runCtx, err := initRunContext(cfg)
	if err != nil {
		return fmt.Errorf("init error: %w", err)
	}

	printBanner()
	printConfig(runCtx.Config)
	if err := ensureAzureReady(); err != nil {
		return err
	}

	ctx := context.Background()
	if err := runPhase(ctx, "Phase 1/4", phase1RecoveryPoints, runCtx); err != nil {
		return err
	}
	if err := runPhase(ctx, "Phase 2/4", phase2NoPolicy, runCtx); err != nil {
		return err
	}
	if err := runPhase(ctx, "Phase 3/4", phase3CrossReference, runCtx); err != nil {
		return err
	}
	if err := runPhase(ctx, "Phase 4/4", phase4Classify, runCtx); err != nil {
		return err
	}

	var retryCtx *RunContext
	if runCtx.Stats.TimeoutCount > 0 && runCtx.Config.RetryVaultsCSV == "" && runCtx.Config.AutoRetryTimeouts {
		retryVaults := make([]VaultInfo, 0, len(runCtx.TimedOut))
		for _, v := range runCtx.TimedOut {
			retryVaults = append(retryVaults, v)
		}
		sortVaults(retryVaults)
		retryCfg := runCtx.Config
		retryCfg.Parallel = runCtx.Config.AutoRetryParallel
		retryCfg.VaultTimeout = runCtx.Config.AutoRetryTimeout
		retryCfg.AutoRetryTimeouts = false
		retryCfg.RetryVaultsCSV = "__in_memory_retry__"
		retryCfg.CSVOutput = false // write retry CSVs to temp dir, not report dir
		retryCfg.TS = time.Now().UTC().Format("20060102-150405")
		retryCtx, err = initRunContext(retryCfg)
		if err != nil {
			return err
		}
		retryCtx.AllVaults = retryVaults
		log.Printf("[*] auto-retry for %d timed-out vault(s)", len(retryVaults))
		if err := runPhase(ctx, "Retry 1/4", phase1RecoveryPoints, retryCtx); err != nil {
			return err
		}
		if err := runPhase(ctx, "Retry 2/4", phase2NoPolicy, retryCtx); err != nil {
			return err
		}
		if err := runPhase(ctx, "Retry 3/4", phase3CrossReference, retryCtx); err != nil {
			return err
		}
		if err := runPhase(ctx, "Retry 4/4", phase4Classify, retryCtx); err != nil {
			return err
		}
	}

	if runCtx.Config.RetryVaultsCSV == "" {
		if err := reconcileFinal(runCtx, retryCtx); err != nil {
			return err
		}
	}
	if retryCtx != nil && retryCtx.Config.ReportDir != runCtx.Config.ReportDir {
		_ = os.RemoveAll(retryCtx.Config.ReportDir)
	}
	printSummary(runCtx, time.Since(start))
	return nil
}

func runPhase(ctx context.Context, title string, fn func(context.Context, *RunContext) error, runCtx *RunContext) error {
	phaseStart := time.Now()
	log.Printf("[%s] starting...", title)
	if err := fn(ctx, runCtx); err != nil {
		return err
	}
	log.Printf("[%s] done in %s", title, formatDuration(time.Since(phaseStart)))
	return nil
}

// Phase 1: scan vaults, collect no-expiry and old recovery points, capture timed-out vaults.
func phase1RecoveryPoints(_ context.Context, runCtx *RunContext) error {
	var err error
	if len(runCtx.AllVaults) == 0 {
		log.Printf("[phase1] discovering vaults via ARG...")
		runCtx.AllVaults, err = loadVaults(runCtx.Config.RetryVaultsCSV)
		if err != nil {
			return err
		}
		log.Printf("[phase1] discovered %d vault(s)", len(runCtx.AllVaults))
	}
	if runCtx.Config.Debug && len(runCtx.AllVaults) > runCtx.Config.DebugMax {
		runCtx.AllVaults = runCtx.AllVaults[:runCtx.Config.DebugMax]
	}
	runCtx.Stats.VaultCount = len(runCtx.AllVaults)
	if len(runCtx.AllVaults) == 0 {
		return nil
	}

	noExpiryHandle, err := os.OpenFile(runCtx.CSV["noExpiry"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer noExpiryHandle.Close()
	oldHandle, err := os.OpenFile(runCtx.CSV["oldRPs"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer oldHandle.Close()
	timeoutHandle, err := os.OpenFile(runCtx.CSV["timeouts"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer timeoutHandle.Close()

	noExpiryWriter := csv.NewWriter(noExpiryHandle)
	oldWriter := csv.NewWriter(oldHandle)
	timeoutWriter := csv.NewWriter(timeoutHandle)
	defer noExpiryWriter.Flush()
	defer oldWriter.Flush()
	defer timeoutWriter.Flush()

	jobs := make(chan VaultInfo)
	var wg sync.WaitGroup
	var noExpiryMu sync.Mutex
	var oldMu sync.Mutex
	var timeoutMu sync.Mutex
	var timedOutMu sync.Mutex
	var started int64
	var completed int64

	workers := runCtx.Config.Parallel
	if workers < 1 {
		workers = 1
	}
	log.Printf("[*] phase1 vault workers=%d total_vaults=%d", workers, len(runCtx.AllVaults))

	doneProgress := make(chan struct{})
	go func(total int) {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				s := atomic.LoadInt64(&started)
				c := atomic.LoadInt64(&completed)
				active := s - c
				log.Printf("[phase1 progress] completed=%d/%d active=%d no-expiry=%d old-rps=%d timeouts=%d",
					c, total, active,
					atomic.LoadInt64(&runCtx.Stats.NoExpiryCount),
					atomic.LoadInt64(&runCtx.Stats.OldRPCount),
					atomic.LoadInt64(&runCtx.Stats.TimeoutCount),
				)
			case <-doneProgress:
				return
			}
		}
	}(len(runCtx.AllVaults))

	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for v := range jobs {
				atomic.AddInt64(&started, 1)
				start := time.Now()
				noExpRows, oldRows, timedOut := processVault(runCtx.Config, v)
				if timedOut {
					timeoutMu.Lock()
					_ = timeoutWriter.Write([]string{v.Subscription, v.ResourceGroup, v.VaultName, strconv.Itoa(int(time.Since(start).Seconds())), ""})
					timeoutWriter.Flush()
					timeoutMu.Unlock()
					timedOutMu.Lock()
					runCtx.TimedOut[vaultKey(v)] = v
					timedOutMu.Unlock()
					atomic.AddInt64(&runCtx.Stats.TimeoutCount, 1)
					atomic.AddInt64(&completed, 1)
					continue
				}
				if len(noExpRows) > 0 {
					noExpiryMu.Lock()
					for _, r := range noExpRows {
						_ = noExpiryWriter.Write(r)
					}
					noExpiryWriter.Flush()
					noExpiryMu.Unlock()
					atomic.AddInt64(&runCtx.Stats.NoExpiryCount, int64(len(noExpRows)))
				}
				if len(oldRows) > 0 {
					oldMu.Lock()
					for _, r := range oldRows {
						_ = oldWriter.Write(r)
					}
					oldWriter.Flush()
					oldMu.Unlock()
					atomic.AddInt64(&runCtx.Stats.OldRPCount, int64(len(oldRows)))
				}
				atomic.AddInt64(&completed, 1)
			}
		}()
	}

	for _, v := range runCtx.AllVaults {
		jobs <- v
	}
	close(jobs)
	wg.Wait()
	close(doneProgress)
	log.Printf("[*] phase1 complete: completed=%d/%d no-expiry=%d old-rps=%d timeouts=%d",
		atomic.LoadInt64(&completed),
		int64(len(runCtx.AllVaults)),
		atomic.LoadInt64(&runCtx.Stats.NoExpiryCount),
		atomic.LoadInt64(&runCtx.Stats.OldRPCount),
		atomic.LoadInt64(&runCtx.Stats.TimeoutCount),
	)
	return nil
}

// Phase 2: query backup items with no assigned policy via Azure Resource Graph.
func phase2NoPolicy(_ context.Context, runCtx *RunContext) error {
	q := `RecoveryServicesResources | where type =~ 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems' | extend vaultName = tostring(split(id, '/')[8]) | extend policyId = tostring(properties.policyId) | extend policyName = tostring(properties.policyInfo.name) | extend protectionState = tostring(properties.currentProtectionState) | extend friendlyName = tostring(properties.friendlyName) | extend itemType = strcat(properties.backupManagementType, '/', properties.workloadType) | extend lastBackupTime = tostring(properties.lastBackupTime) | where isempty(policyId) and isempty(policyName) | project subscriptionId, resourceGroup, vaultName, friendlyName, itemType, protectionState, lastBackupTime`
	f, err := os.OpenFile(runCtx.CSV["noPolicy"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	w := csv.NewWriter(f)
	defer w.Flush()

	const pageSize = 100
	skip := 0
	for {
		out, err := runAzJSON("graph", "query", "-q", q, "--first", strconv.Itoa(pageSize), "--skip", strconv.Itoa(skip))
		if err != nil {
			return err
		}
		rows, total, _, err := extractDataWithTotal(out)
		if err != nil {
			return err
		}
		for _, row := range rows {
			record := []string{
				getAny(row, "subscriptionId", "subscriptionID"),
				getAny(row, "resourceGroup", "resourcegroup"),
				getAny(row, "vaultName", "vaultname"),
				getAny(row, "friendlyName", "friendlyname"),
				getAny(row, "itemType", "itemtype"),
				getAny(row, "protectionState", "protectionstate"),
				normalizeOutputTime(getAny(row, "lastBackupTime", "lastbackuptime"), runCtx.Config.OutputTimeMode),
			}
			if strings.Contains(strings.ToLower(record[4]), "azureiaasvm") {
				runCtx.Stats.NoPolicyVMCount++
			}
			runCtx.Stats.NoPolicyCount++
			if err := w.Write(record); err != nil {
				return err
			}
		}
		w.Flush()
		if len(rows) == 0 {
			break
		}
		skip += pageSize
		if total > 0 && skip >= total {
			break
		}
	}
	return nil
}

// Phase 3: cross-reference phase 1 and phase 2 outputs.
func phase3CrossReference(_ context.Context, runCtx *RunContext) error {
	type stat struct {
		Count  int
		Oldest string
	}
	rpStats := map[string]stat{}

	rf, err := os.Open(runCtx.CSV["noExpiry"])
	if err != nil {
		return err
	}
	defer rf.Close()
	rr := csv.NewReader(rf)
	_, _ = rr.Read()
	for {
		row, err := rr.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if len(row) < 6 {
			continue
		}
		key := strings.ToLower(row[2] + "|" + vmKey(row[3]))
		cur := rpStats[key]
		cur.Count++
		if cur.Oldest == "" || row[4] < cur.Oldest {
			cur.Oldest = row[4]
		}
		rpStats[key] = cur
	}

	inf, err := os.Open(runCtx.CSV["noPolicy"])
	if err != nil {
		return err
	}
	defer inf.Close()
	inr := csv.NewReader(inf)
	_, _ = inr.Read()

	outf, err := os.OpenFile(runCtx.CSV["overlap"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer outf.Close()
	ow := csv.NewWriter(outf)
	defer ow.Flush()

	for {
		row, err := inr.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if len(row) < 7 {
			continue
		}
		key := strings.ToLower(row[2] + "|" + row[3])
		s, ok := rpStats[key]
		if !ok {
			continue
		}
		runCtx.Stats.OverlapCount++
		if err := ow.Write(append(row, strconv.Itoa(s.Count), s.Oldest)); err != nil {
			return err
		}
	}
	return nil
}

// Phase 4: classify vaults into clean/dirty buckets by reason.
func phase4Classify(_ context.Context, runCtx *RunContext) error {
	type reasonSet map[string]struct{}
	dirty := map[string]reasonSet{}
	addReason := func(k, r string) {
		if dirty[k] == nil {
			dirty[k] = reasonSet{}
		}
		dirty[k][r] = struct{}{}
	}
	if err := collectReason(runCtx.CSV["overlap"], "no-policy-no-expiry", addReason); err != nil {
		return err
	}
	if err := collectReason(runCtx.CSV["oldRPs"], "old-rps", addReason); err != nil {
		return err
	}
	if err := collectReason(runCtx.CSV["timeouts"], "timeout", addReason); err != nil {
		return err
	}

	df, err := os.OpenFile(runCtx.CSV["dirty"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer df.Close()
	dw := csv.NewWriter(df)
	defer dw.Flush()

	keys := make([]string, 0, len(dirty))
	for k := range dirty {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		sub, rg, vault := splitKey(k)
		rs := make([]string, 0, len(dirty[k]))
		for r := range dirty[k] {
			rs = append(rs, r)
		}
		sort.Strings(rs)
		if err := dw.Write([]string{sub, rg, vault, strings.Join(rs, ";")}); err != nil {
			return err
		}
	}

	cf, err := os.OpenFile(runCtx.CSV["clean"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer cf.Close()
	cw := csv.NewWriter(cf)
	defer cw.Flush()
	for _, v := range runCtx.AllVaults {
		if _, ok := dirty[vaultKey(v)]; ok {
			continue
		}
		if err := cw.Write([]string{v.Subscription, v.ResourceGroup, v.VaultName}); err != nil {
			return err
		}
		runCtx.Stats.CleanCount++
	}
	runCtx.Stats.DirtyCount = int64(len(dirty))
	return nil
}

// Config and filesystem setup.
func loadConfig() (Config, error) {
	repoRoot, err := os.Getwd()
	if err != nil {
		return Config{}, err
	}
	ts := time.Now().UTC().Format("20060102-150405")
	reportDir := filepath.Join(filepath.Dir(repoRoot), "rsv-reports")

	cfg := Config{
		Debug:             envBool("DEBUG", false),
		DebugPaging:       envBool("DEBUG_PAGING", false),
		DebugMax:          envInt("DEBUG_MAX", 3),
		Parallel:          envInt("PARALLEL", 10),
		SkipRecentHours:   envInt("SKIP_RECENT_HOURS", 48),
		RPAgeMonths:       envInt("RP_AGE_MONTHS", 13),
		CSVOutput:         envBool("CSV_OUTPUT", true),
		VaultTimeout:      time.Duration(envInt("VAULT_TIMEOUT", 600)) * time.Second,
		RetryVaultsCSV:    os.Getenv("RETRY_VAULTS_CSV"),
		AutoRetryTimeouts: envBool("AUTO_RETRY_TIMEOUTS", true),
		AutoRetryParallel: envInt("AUTO_RETRY_PARALLEL", 5),
		AutoRetryTimeout:  time.Duration(envInt("AUTO_RETRY_TIMEOUT", 1200)) * time.Second,
		OutputTimeMode:    normalizeOutputTimeMode(os.Getenv("REPORT_TIME_MODE")),
		ReportDir:         reportDir,
		TS:                ts,
	}
	if v := strings.TrimSpace(os.Getenv("REPORT_DIR")); v != "" {
		cfg.ReportDir = v
	}
	if cfg.Parallel <= 0 {
		return Config{}, fmt.Errorf("PARALLEL must be > 0")
	}
	if cfg.DebugMax <= 0 {
		return Config{}, fmt.Errorf("DEBUG_MAX must be > 0")
	}
	return cfg, nil
}

func initRunContext(cfg Config) (*RunContext, error) {
	if cfg.CSVOutput {
		if err := ensureWritableDir(cfg.ReportDir); err != nil {
			return nil, fmt.Errorf("cannot use REPORT_DIR %q: %w", cfg.ReportDir, err)
		}
	}

	baseDir := cfg.ReportDir
	if !cfg.CSVOutput {
		tmpDir, err := os.MkdirTemp("", "rsv-readiness-go-*")
		if err != nil {
			return nil, err
		}
		baseDir = tmpDir
	}

	csvPaths := map[string]string{
		"noExpiry":    filepath.Join(baseDir, fmt.Sprintf("1-no-expiry-rps-%s.csv", cfg.TS)),
		"noPolicy":    filepath.Join(baseDir, fmt.Sprintf("2-no-policy-items-%s.csv", cfg.TS)),
		"overlap":     filepath.Join(baseDir, fmt.Sprintf("3-no-expiry-no-policy-%s.csv", cfg.TS)),
		"oldRPs":      filepath.Join(baseDir, fmt.Sprintf("4-old-rps-%s.csv", cfg.TS)),
		"clean":       filepath.Join(baseDir, fmt.Sprintf("5-clean-vaults-%s.csv", cfg.TS)),
		"dirty":       filepath.Join(baseDir, fmt.Sprintf("6-dirty-vaults-%s.csv", cfg.TS)),
		"timeouts":    filepath.Join(baseDir, fmt.Sprintf("7-timed-out-vaults-%s.csv", cfg.TS)),
		"finalClean":  filepath.Join(baseDir, fmt.Sprintf("8-final-clean-vaults-%s.csv", cfg.TS)),
		"finalDirty":  filepath.Join(baseDir, fmt.Sprintf("9-final-dirty-vaults-%s.csv", cfg.TS)),
		"dirtyDetail": filepath.Join(baseDir, fmt.Sprintf("10-dirty-items-detail-%s.csv", cfg.TS)),
		"cleanList":   filepath.Join(baseDir, fmt.Sprintf("clean-vaults-%s.list", cfg.TS)),
	}

	headers := map[string]string{
		"noExpiry":    "subscription,resourceGroup,vaultName,itemName,recoveryPointTime,recoveryPointType",
		"noPolicy":    "subscriptionId,resourceGroup,vaultName,friendlyName,itemType,protectionState,lastBackupTime",
		"overlap":     "subscriptionId,resourceGroup,vaultName,friendlyName,itemType,protectionState,lastBackupTime,noExpiryRpCount,oldestNoExpiryRp",
		"oldRPs":      "subscription,resourceGroup,vaultName,itemName,recoveryPointTime,recoveryPointType,expiryTime",
		"clean":       "subscription,resourceGroup,vaultName",
		"dirty":       "subscription,resourceGroup,vaultName,reason",
		"timeouts":    "subscription,resourceGroup,vaultName,elapsedSeconds,pid",
		"finalClean":  "subscription,resourceGroup,vaultName",
		"finalDirty":  "subscription,resourceGroup,vaultName,reason",
		"dirtyDetail": "subscription,resourceGroup,vaultName,reason,itemName,recoveryPointTime,recoveryPointType,expiryTime",
	}
	for key, path := range csvPaths {
		if h, ok := headers[key]; ok {
			if err := os.WriteFile(path, []byte(h+"\n"), 0o644); err != nil {
				return nil, err
			}
		} else {
			if err := os.WriteFile(path, nil, 0o644); err != nil {
				return nil, err
			}
		}
	}

	return &RunContext{Config: cfg, CSV: csvPaths, TimedOut: map[string]VaultInfo{}}, nil
}

func ensureWritableDir(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	testFile, err := os.CreateTemp(dir, ".write-test-*")
	if err != nil {
		return err
	}
	_ = testFile.Close()
	_ = os.Remove(testFile.Name())
	return nil
}

// External command helpers.
func ensureAzureReady() error {
	if _, err := exec.LookPath("az"); err != nil {
		return fmt.Errorf("az CLI is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, err := runCmd(ctx, "az", "account", "show", "-o", "json"); err != nil {
		return fmt.Errorf("azure CLI not authenticated, run az login")
	}
	return nil
}

// Vault scanning and reconciliation helpers.
func processVault(cfg Config, vault VaultInfo) ([][]string, [][]string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), cfg.VaultTimeout)
	defer cancel()

	itemsJSON, err := runAzJSONWithContext(ctx, "backup", "item", "list", "--subscription", vault.Subscription, "--resource-group", vault.ResourceGroup, "--vault-name", vault.VaultName, "--backup-management-type", "AzureIaasVM", "--workload-type", "VM")
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return nil, nil, true
		}
		if !isResourceNotFoundErr(err) {
			log.Printf("[phase1] item list failed for vault %s/%s: %v", vault.ResourceGroup, vault.VaultName, err)
		}
		return nil, nil, false
	}
	var items []struct {
		Name       string `json:"name"`
		Properties struct {
			ContainerName string `json:"containerName"`
		} `json:"properties"`
	}
	if err := json.Unmarshal(itemsJSON, &items); err != nil {
		return nil, nil, false
	}

	now := time.Now().UTC()
	oldCutoff := now.AddDate(0, -cfg.RPAgeMonths, 0)
	var recentCutoff *time.Time
	if cfg.SkipRecentHours > 0 {
		t := now.Add(-time.Duration(cfg.SkipRecentHours) * time.Hour)
		recentCutoff = &t
	}

	noExpiryRows := make([][]string, 0)
	oldRows := make([][]string, 0)
	for _, item := range items {
		containerName := "IaasVMContainer;" + item.Properties.ContainerName
		rpJSON, err := runAzJSONWithContext(ctx, "backup", "recoverypoint", "list", "--subscription", vault.Subscription, "--resource-group", vault.ResourceGroup, "--vault-name", vault.VaultName, "--container-name", containerName, "--item-name", item.Name, "--backup-management-type", "AzureIaasVM", "--workload-type", "VM")
		if err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				return nil, nil, true
			}
			if !isResourceNotFoundErr(err) {
				log.Printf("[phase1] recoverypoint list failed for vault %s/%s item %s: %v", vault.ResourceGroup, vault.VaultName, item.Name, err)
			}
			continue
		}

		var rps []struct {
			Name       string `json:"name"`
			Properties struct {
				RecoveryPointTime       string `json:"recoveryPointTime"`
				RecoveryPointType       string `json:"recoveryPointType"`
				RecoveryPointProperties struct {
					ExpiryTime *string `json:"expiryTime"`
				} `json:"recoveryPointProperties"`
			} `json:"properties"`
		}
		if err := json.Unmarshal(rpJSON, &rps); err != nil {
			continue
		}

		for _, rp := range rps {
			t, err := parseTime(rp.Properties.RecoveryPointTime)
			if err != nil {
				continue
			}
			if t.Before(oldCutoff) {
				expiry := ""
				if rp.Properties.RecoveryPointProperties.ExpiryTime != nil {
					expiry = normalizeOutputTime(*rp.Properties.RecoveryPointProperties.ExpiryTime, cfg.OutputTimeMode)
				}
				oldRows = append(oldRows, []string{
					vault.Subscription,
					vault.ResourceGroup,
					vault.VaultName,
					item.Name,
					normalizeOutputTime(rp.Properties.RecoveryPointTime, cfg.OutputTimeMode),
					rp.Properties.RecoveryPointType,
					expiry,
				})
			}
			if rp.Properties.RecoveryPointProperties.ExpiryTime == nil {
				if recentCutoff != nil && t.After(*recentCutoff) {
					continue
				}
				noExpiryRows = append(noExpiryRows, []string{
					vault.Subscription,
					vault.ResourceGroup,
					vault.VaultName,
					item.Name,
					normalizeOutputTime(rp.Properties.RecoveryPointTime, cfg.OutputTimeMode),
					rp.Properties.RecoveryPointType,
				})
			}
		}
	}
	return noExpiryRows, oldRows, false
}

func loadVaults(retryPath string) ([]VaultInfo, error) {
	if strings.TrimSpace(retryPath) != "" {
		log.Printf("[phase1] loading vault list from RETRY_VAULTS_CSV=%s", retryPath)
		return readVaultsCSV(retryPath)
	}
	query := `Resources | where type =~ 'microsoft.recoveryservices/vaults' | project id`
	out := make([]VaultInfo, 0)
	seen := make(map[string]struct{})
	// az graph query --first 1000 auto-pages internally in the CLI
	// and returns all results in a single call — same as the bash script.
	body, err := runAzJSON("graph", "query", "-q", query, "--first", "1000")
	if err != nil {
		return nil, err
	}
	rows, _, _, err := extractDataWithTotal(body)
	if err != nil {
		return nil, err
	}
	log.Printf("[phase1] ARG returned %d rows in data array", len(rows))
	skipped := 0
	for _, r := range rows {
		v, ok := vaultInfoFromResourceID(getAny(r, "id", "Id"))
		if !ok {
			skipped++
			continue
		}
		k := vaultKey(v)
		if _, ok := seen[k]; ok {
			continue
		}
		seen[k] = struct{}{}
		out = append(out, v)
	}
	if skipped > 0 {
		log.Printf("[phase1] WARNING: %d rows skipped (could not parse resource ID)", skipped)
	}
	log.Printf("[phase1] parsed %d unique vaults from %d rows", len(out), len(rows))
	return out, nil
}

// Final reconciliation helpers.
func reconcileFinal(base, retry *RunContext) error {
	baseDirty, err := readDirty(base.CSV["dirty"])
	if err != nil {
		return err
	}
	baseTimeout, err := readSet(base.CSV["timeouts"])
	if err != nil {
		return err
	}
	retryDirty := map[string]string{}
	retryTimeout := map[string]struct{}{}
	if retry != nil {
		retryDirty, err = readDirty(retry.CSV["dirty"])
		if err != nil {
			return err
		}
		retryTimeout, err = readSet(retry.CSV["timeouts"])
		if err != nil {
			return err
		}
	}

	finalDirty := map[string]string{}
	for _, v := range base.AllVaults {
		k := vaultKey(v)
		if _, wasTimeout := baseTimeout[k]; wasTimeout {
			if _, stillTimeout := retryTimeout[k]; stillTimeout {
				if r, ok := retryDirty[k]; ok && r != "" {
					finalDirty[k] = r
				} else {
					finalDirty[k] = "timeout"
				}
			} else if r, ok := retryDirty[k]; ok {
				finalDirty[k] = r
			}
			continue
		}
		if r, ok := baseDirty[k]; ok {
			finalDirty[k] = r
		}
	}
	if err := writeFinal(base, finalDirty); err != nil {
		return err
	}
	base.Stats.FinalDirtyCount = int64(len(finalDirty))
	base.Stats.FinalCleanCount = int64(len(base.AllVaults) - len(finalDirty))
	return nil
}

func writeFinal(base *RunContext, dirty map[string]string) error {
	df, err := os.OpenFile(base.CSV["finalDirty"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer df.Close()
	dw := csv.NewWriter(df)
	defer dw.Flush()
	keys := make([]string, 0, len(dirty))
	for k := range dirty {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		s, rg, v := splitKey(k)
		if err := dw.Write([]string{s, rg, v, dirty[k]}); err != nil {
			return err
		}
	}

	cf, err := os.OpenFile(base.CSV["finalClean"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer cf.Close()
	cw := csv.NewWriter(cf)
	defer cw.Flush()
	for _, v := range base.AllVaults {
		if _, ok := dirty[vaultKey(v)]; ok {
			continue
		}
		if err := cw.Write([]string{v.Subscription, v.ResourceGroup, v.VaultName}); err != nil {
			return err
		}
	}

	if base.Config.CSVOutput {
		if err := writeDirtyDetail(base, dirty); err != nil {
			return err
		}
		if err := writeCleanList(base, dirty); err != nil {
			return err
		}
	}
	return nil
}

func writeDirtyDetail(base *RunContext, dirty map[string]string) error {
	// Build set of dirty vault keys for quick lookup
	dirtyVaults := map[string]string{}
	for k, r := range dirty {
		_, _, v := splitKey(k)
		dirtyVaults[k] = r
		_ = v
	}

	// Collect items from no-expiry RPs (file 1)
	type detailRow struct {
		sub, rg, vault, reason, item, rpTime, rpType, expiry string
	}
	var rows []detailRow

	addFromCSV := func(path, reason string, itemCol, rpTimeCol, rpTypeCol, expiryCol int) error {
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		r := csv.NewReader(f)
		if _, err := r.Read(); err != nil {
			return nil // empty file
		}
		for {
			rec, err := r.Read()
			if err == io.EOF {
				break
			}
			if err != nil {
				return err
			}
			if len(rec) < 3 {
				continue
			}
			k := strings.ToLower(rec[0] + "|" + rec[1] + "|" + rec[2])
			if _, ok := dirtyVaults[k]; !ok {
				continue
			}
			item, rpTime, rpType, expiry := "", "", "", ""
			if itemCol >= 0 && itemCol < len(rec) {
				item = rec[itemCol]
			}
			if rpTimeCol >= 0 && rpTimeCol < len(rec) {
				rpTime = rec[rpTimeCol]
			}
			if rpTypeCol >= 0 && rpTypeCol < len(rec) {
				rpType = rec[rpTypeCol]
			}
			if expiryCol >= 0 && expiryCol < len(rec) {
				expiry = rec[expiryCol]
			}
			rows = append(rows, detailRow{rec[0], rec[1], rec[2], reason, item, rpTime, rpType, expiry})
		}
		return nil
	}

	// file 3: no-expiry + no-policy overlap (friendlyName=col3)
	if err := addFromCSV(base.CSV["overlap"], "no-policy-no-expiry", 3, -1, -1, -1); err != nil {
		return err
	}
	// file 4: old RPs (itemName=col3, rpTime=col4, rpType=col5, expiry=col6)
	if err := addFromCSV(base.CSV["oldRPs"], "old-rp", 3, 4, 5, 6); err != nil {
		return err
	}

	df, err := os.OpenFile(base.CSV["dirtyDetail"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer df.Close()
	w := csv.NewWriter(df)
	defer w.Flush()
	for _, r := range rows {
		if err := w.Write([]string{r.sub, r.rg, r.vault, r.reason, r.item, r.rpTime, r.rpType, r.expiry}); err != nil {
			return err
		}
	}
	return nil
}

func writeCleanList(base *RunContext, dirty map[string]string) error {
	f, err := os.OpenFile(base.CSV["cleanList"], os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, v := range base.AllVaults {
		if _, ok := dirty[vaultKey(v)]; ok {
			continue
		}
		if _, err := fmt.Fprintln(f, v.VaultName); err != nil {
			return err
		}
	}
	return nil
}

// CSV readers and collectors.
func readVaultsCSV(path string) ([]VaultInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	r := csv.NewReader(f)
	first, err := r.Read()
	if err != nil {
		return nil, err
	}
	out := make([]VaultInfo, 0)
	if len(first) >= 3 && !strings.EqualFold(strings.TrimSpace(first[0]), "subscription") {
		out = append(out, VaultInfo{Subscription: first[0], ResourceGroup: first[1], VaultName: first[2]})
	}
	for {
		row, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if len(row) < 3 {
			continue
		}
		out = append(out, VaultInfo{Subscription: row[0], ResourceGroup: row[1], VaultName: row[2]})
	}
	return out, nil
}

func collectReason(path, reason string, add func(string, string)) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	r := csv.NewReader(f)
	_, _ = r.Read()
	for {
		row, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if len(row) < 3 {
			continue
		}
		add(vaultKey(VaultInfo{Subscription: row[0], ResourceGroup: row[1], VaultName: row[2]}), reason)
	}
	return nil
}

func readDirty(path string) (map[string]string, error) {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out, err
	}
	defer f.Close()
	r := csv.NewReader(f)
	_, _ = r.Read()
	for {
		row, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return out, err
		}
		if len(row) < 4 {
			continue
		}
		out[vaultKey(VaultInfo{Subscription: row[0], ResourceGroup: row[1], VaultName: row[2]})] = row[3]
	}
	return out, nil
}

func readSet(path string) (map[string]struct{}, error) {
	out := map[string]struct{}{}
	f, err := os.Open(path)
	if err != nil {
		return out, err
	}
	defer f.Close()
	r := csv.NewReader(f)
	_, _ = r.Read()
	for {
		row, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return out, err
		}
		if len(row) < 3 {
			continue
		}
		out[vaultKey(VaultInfo{Subscription: row[0], ResourceGroup: row[1], VaultName: row[2]})] = struct{}{}
	}
	return out, nil
}

// Generic utility helpers.
func runAzJSON(args ...string) ([]byte, error) {
	args = append(args, "-o", "json")
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	return runCmd(ctx, "az", args...)
}

func runAzJSONWithContext(ctx context.Context, args ...string) ([]byte, error) {
	args = append(args, "-o", "json")
	return runCmd(ctx, "az", args...)
}

func runCmd(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("%s", strings.TrimSpace(string(out)))
	}
	return out, nil
}

func extractData(raw []byte) ([]map[string]any, error) {
	rows, _, _, err := extractDataWithTotal(raw)
	return rows, err
}

func extractDataWithTotal(raw []byte) ([]map[string]any, int, string, error) {
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, 0, "", err
	}
	arr, ok := payload["data"].([]any)
	if !ok {
		return []map[string]any{}, 0, "", nil
	}
	out := make([]map[string]any, 0, len(arr))
	for _, item := range arr {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out, getInt(payload, "totalRecords", "total_records", "count"), getAny(payload, "skipToken", "$skipToken", "skip_token"), nil
}

func parseTime(value string) (time.Time, error) {
	layouts := []string{time.RFC3339Nano, time.RFC3339, "2006-01-02T15:04:05"}
	for _, layout := range layouts {
		if t, err := time.Parse(layout, value); err == nil {
			return t.UTC(), nil
		}
	}
	if len(value) >= 19 {
		return time.Parse("2006-01-02T15:04:05", value[:19])
	}
	return time.Time{}, fmt.Errorf("cannot parse time")
}

func normalizeOutputTime(value, mode string) string {
	if strings.TrimSpace(value) == "" {
		return value
	}
	t, err := parseTime(value)
	if err != nil {
		return value
	}
	return formatOutputTime(t.UTC(), mode)
}

func formatOutputTime(t time.Time, mode string) string {
	switch mode {
	case "datetime":
		return t.Format("2006-01-02 15:04:05 UTC")
	case "date":
		fallthrough
	default:
		return t.Format("2006-01-02")
	}
}

func normalizeOutputTimeMode(raw string) string {
	mode := strings.TrimSpace(strings.ToLower(raw))
	if mode == "" {
		return "date"
	}
	switch mode {
	case "date", "datetime":
		return mode
	default:
		return "date"
	}
}

func get(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

func getAny(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v := get(m, k); strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func getInt(m map[string]any, keys ...string) int {
	for _, key := range keys {
		v, ok := m[key]
		if !ok || v == nil {
			continue
		}
		switch t := v.(type) {
		case float64:
			return int(t)
		case int:
			return t
		case string:
			n, _ := strconv.Atoi(strings.TrimSpace(t))
			return n
		}
	}
	return 0
}

func isResourceNotFoundErr(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "resourcenotfound") || strings.Contains(msg, "resource not found")
}

func last(s string) string {
	parts := strings.Split(s, ";")
	if len(parts) == 0 {
		return s
	}
	return parts[len(parts)-1]
}

func vmKey(item string) string {
	return strings.ToLower(last(item))
}

func vaultKey(v VaultInfo) string {
	return strings.ToLower(v.Subscription + "|" + v.ResourceGroup + "|" + v.VaultName)
}

func vaultInfoFromResourceID(id string) (VaultInfo, bool) {
	raw := strings.TrimSpace(id)
	if raw == "" {
		return VaultInfo{}, false
	}
	parts := strings.Split(raw, "/")
	// Expected:
	// /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.RecoveryServices/vaults/{name}
	if len(parts) < 9 {
		return VaultInfo{}, false
	}
	if strings.ToLower(parts[1]) != "subscriptions" || strings.ToLower(parts[3]) != "resourcegroups" {
		return VaultInfo{}, false
	}
	v := VaultInfo{
		Subscription:  parts[2],
		ResourceGroup: parts[4],
		VaultName:     parts[len(parts)-1],
	}
	if v.Subscription == "" || v.ResourceGroup == "" || v.VaultName == "" {
		return VaultInfo{}, false
	}
	return v, true
}

func splitKey(k string) (string, string, string) {
	parts := strings.SplitN(k, "|", 3)
	if len(parts) != 3 {
		return "", "", ""
	}
	return parts[0], parts[1], parts[2]
}

func sortVaults(vaults []VaultInfo) {
	sort.Slice(vaults, func(i, j int) bool {
		if vaults[i].Subscription != vaults[j].Subscription {
			return vaults[i].Subscription < vaults[j].Subscription
		}
		if vaults[i].ResourceGroup != vaults[j].ResourceGroup {
			return vaults[i].ResourceGroup < vaults[j].ResourceGroup
		}
		return vaults[i].VaultName < vaults[j].VaultName
	})
}

// Output rendering helpers.
func printBanner() {
	fmt.Println("=============================================")
	fmt.Println(" RSV Immutability Readiness Check (Go)")
	fmt.Printf(" %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Println("=============================================")
}

func printConfig(cfg Config) {
	log.Printf("[*] PARALLEL=%d, DEBUG=%t, SKIP_RECENT_HOURS=%d, RP_AGE_MONTHS=%d", cfg.Parallel, cfg.Debug, cfg.SkipRecentHours, cfg.RPAgeMonths)
	log.Printf("[*] VAULT_TIMEOUT=%s, AUTO_RETRY=%t (%d/%s)", cfg.VaultTimeout, cfg.AutoRetryTimeouts, cfg.AutoRetryParallel, cfg.AutoRetryTimeout)
	log.Printf("[*] DEBUG_PAGING=%t", cfg.DebugPaging)
	log.Printf("[*] REPORT_TIME_MODE=%s", cfg.OutputTimeMode)
	if cfg.RetryVaultsCSV != "" {
		log.Printf("[*] RETRY_VAULTS_CSV=%s", cfg.RetryVaultsCSV)
	}
	log.Printf("[*] REPORT_DIR=%s", cfg.ReportDir)
}

func printSummary(runCtx *RunContext, elapsed time.Duration) {
	fmt.Println()
	fmt.Println("=============================================")
	fmt.Println(" SUMMARY — RSV Immutability Readiness (Go)")
	fmt.Println("=============================================")
	fmt.Printf("  %-40s %d\n", "Total vaults scanned:", runCtx.Stats.VaultCount)
	fmt.Printf("  %-40s %d\n", "No-expiry RPs:", runCtx.Stats.NoExpiryCount)
	fmt.Printf("  %-40s %d\n", "No-policy items:", runCtx.Stats.NoPolicyCount)
	fmt.Printf("  %-40s %d\n", "Overlap items:", runCtx.Stats.OverlapCount)
	fmt.Printf("  %-40s %d\n", "Old RPs:", runCtx.Stats.OldRPCount)
	fmt.Printf("  %-40s %d\n", "Clean vaults:", runCtx.Stats.CleanCount)
	fmt.Printf("  %-40s %d\n", "Dirty vaults:", runCtx.Stats.DirtyCount)
	fmt.Printf("  %-40s %d\n", "Timed-out vaults:", runCtx.Stats.TimeoutCount)
	if runCtx.Config.RetryVaultsCSV == "" {
		fmt.Printf("  %-40s %d\n", "Final clean vaults:", runCtx.Stats.FinalCleanCount)
		fmt.Printf("  %-40s %d\n", "Final dirty vaults:", runCtx.Stats.FinalDirtyCount)
		if total := runCtx.Stats.FinalCleanCount + runCtx.Stats.FinalDirtyCount; total != int64(runCtx.Stats.VaultCount) {
			fmt.Printf("  ⚠ MISMATCH: final clean (%d) + dirty (%d) = %d, expected %d\n",
				runCtx.Stats.FinalCleanCount, runCtx.Stats.FinalDirtyCount, total, runCtx.Stats.VaultCount)
		}
	}
	fmt.Printf("  %-40s %s\n", "Total execution time:", formatDuration(elapsed))
	fmt.Println("=============================================")
}

func envInt(key string, def int) int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return n
}

func envBool(key string, def bool) bool {
	raw := strings.TrimSpace(strings.ToLower(os.Getenv(key)))
	if raw == "" {
		return def
	}
	switch raw {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return def
	}
}

func formatDuration(d time.Duration) string {
	secs := int(d.Seconds())
	if secs < 60 {
		return fmt.Sprintf("%ds", secs)
	}
	return fmt.Sprintf("%dm %ds", secs/60, secs%60)
}
