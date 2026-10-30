# CCDC Linux Phase 2 Combined Script — Design Plan

**Status:** PLANNED — script not yet built  
**Target file:** `Phase_2_Tools/General_Scripts/SetupScripts/linux/CCDC_Linux_COMBINED.sh`  
**MITRE coverage:** T1014, T1055.008, T1070, T1072, T1205.001, T1489, T1525, T1542.001

---

## Overview

The 8 individual Phase 2 Linux scripts each have to be transferred to a target host separately, which is slow and leaves more artifacts. `CCDC_Linux_COMBINED.sh` solves this by inlining all 8 modules into a single file that can be downloaded once and run with a module selector. It also tracks which modules have already fired so operators can pick up where they left off without re-running things that already worked.

**What it solves:**
- One `wget`/`curl` instead of eight
- Persistent state survives SSH disconnects — run status is readable before resuming
- `--all` fires everything in the correct order (rootkit first, antiforensics last) without manual sequencing
- A failed module logs and continues; it does not abort the remaining queue

---

## Architecture

```
CCDC_Linux_COMBINED.sh
├── ### OPERATOR CONFIG ###      ← single block, all vars here
├── Shared helpers               ← print_info/warn/error/success/section
│   ├── check_root()
│   ├── detect_distro()
│   ├── mark_state()
│   ├── get_state()
│   └── print_state_table()
├── Module functions (8)
│   ├── run_rootkit()            ← KernelSneak body
│   ├── run_docker_poisoner()    ← DockerPoisoner body
│   ├── run_preosboot()          ← BootStrap body
│   ├── run_process_inject()     ← PTraced body
│   ├── run_service_sabotage()   ← BrokenClock body
│   ├── run_software_deploy()    ← ChefMischief body
│   ├── run_traffic_signal()     ← KnockKnock body
│   └── run_antiforensics()      ← VanishingAct body (run LAST)
└── main()                       ← arg parsing, menu, dispatch
```

**Error isolation:** `set -euo pipefail` is set **inside** each `run_*()` function using a subshell, NOT at the script top level. A module that exits non-zero is caught, marked `FAILED`, and the next module runs.

```bash
run_module() {
    local name="$1"
    local fn="run_${name}"
    if [[ "$(get_state "$name")" == "SUCCESS" ]] && [[ "$FORCE" != "1" ]]; then
        echo "[SKIP] $name already ran successfully"
        return 0
    fi
    ( set -euo pipefail; "$fn" ) && mark_state "$name" SUCCESS || mark_state "$name" FAILED
}
```

---

## Modules

| # | Key | Origin Script | MITRE | Short Description |
|---|-----|---------------|-------|-------------------|
| 1 | `rootkit` | `CCDC_Linux_Rootkit_KernelSneak.sh` | T1014 | LKM rootkit hiding processes/files/ports |
| 2 | `docker_poisoner` | `CCDC_Linux_ImplantImage_DockerPoisoner.sh` | T1525 | Poisoned Docker image planting host persistence |
| 3 | `preosboot` | `CCDC_Linux_PreOSBoot_BootStrap.sh` | T1542.001 | initramfs hook surviving reboots/wipes |
| 4 | `process_inject` | `CCDC_Linux_ProcessInject_PTraced.sh` | T1055.008 | ptrace injection into systemd-journald |
| 5 | `service_sabotage` | `CCDC_Linux_ServiceSabotage_BrokenClock.sh` | T1489 | Three-layer attack on Dovecot/Postfix/Apache/Splunk/OpenCart |
| 6 | `software_deploy` | `CCDC_Linux_SoftwareDeploy_ChefMischief.sh` | T1072 | Malicious Chef cookbook re-applying persistence every 15 min |
| 7 | `traffic_signal` | `CCDC_Linux_TrafficSignal_KnockKnock.sh` | T1205.001 | Port-knock backdoor (3-stage iptables sequence) |
| 8 | `antiforensics` | `CCDC_Linux_AntiForensics_VanishingAct.sh` | T1070 | Log wipe, timestomp, self-destruct (run LAST) |

---

## State Tracking

**State file:** `/var/lib/.p2_state`  
Persists across reboots. Hidden dot-file in a low-attention directory.

**Format** (one line per module):
```
rootkit|SUCCESS|2026-10-04T14:32:11
docker_poisoner|FAILED|2026-10-04T14:33:05
preosboot|PENDING|
```

**State values:**
| Status | Meaning |
|--------|---------|
| `PENDING` | Not yet attempted this session |
| `SUCCESS` | Module completed without error |
| `FAILED` | Module exited non-zero |
| `SKIPPED` | Skipped by user or dependency check |

**Helper functions:**
```bash
mark_state()    # mark_state <module> <STATUS>
get_state()     # returns current status string for a module
print_state_table()  # prints formatted table of all module statuses
```

---

## Invocation

```bash
# Interactive numbered menu (default when no args)
sudo bash CCDC_Linux_COMBINED.sh

# Run specific modules by key
sudo bash CCDC_Linux_COMBINED.sh --modules rootkit,service_sabotage

# Run all in recommended order
sudo bash CCDC_Linux_COMBINED.sh --all

# Show current run state without executing anything
sudo bash CCDC_Linux_COMBINED.sh --status

# Force re-run even if previously succeeded
sudo bash CCDC_Linux_COMBINED.sh --modules antiforensics --force

# Run all, skipping modules that already succeeded
sudo bash CCDC_Linux_COMBINED.sh --all --resume
```

**`--all` execution order:**
```
1. rootkit          (hides subsequent tools from ps/ls/ss)
2. docker_poisoner
3. preosboot
4. process_inject
5. service_sabotage
6. software_deploy
7. traffic_signal
8. antiforensics    (erases evidence of everything above)
```

Rootkit runs first so it's hiding all later-dropped files and processes. AntiForensics runs last so it cleans up artifacts from all other modules.

---

## Operator Config Block

All variables that must be changed before deployment are consolidated at the top:

```bash
### OPERATOR CONFIG — CHANGE ALL OF THESE BEFORE DEPLOYING ###

ATTACKER_IP="CHANGEME"           # Your C2 / listener IP
ATTACKER_PORT="4444"             # Default reverse shell port
ATTACKER_SSH_PUBKEY="CHANGEME"   # Your SSH public key (full line)
KNOCK_PORT_1="7001"              # Port knock sequence port 1
KNOCK_PORT_2="7002"              # Port knock sequence port 2
KNOCK_PORT_3="7003"              # Port knock sequence port 3
KNOCK_CALLBACK_PORT="4448"       # Knock trigger fires shell to this port
PTRACE_PORT="4445"               # Process inject shell port
CHEF_PORT="4446"                 # Chef cookbook reverse shell port
DOCKER_PORT="4444"               # Docker poisoner shell port
VANISHINGACT_PASSPHRASE="CHANGEME"  # AntiForensics gate passphrase
OPERATOR_USER="CHANGEME"         # Your operator username for log scrubbing

### END OPERATOR CONFIG ###
```

The script validates none of these are still `"CHANGEME"` before running any module and aborts with a clear error if they are.

---

## Module Inlining Approach

When building the combined script from the 8 individual scripts:

1. Each individual script's body becomes a `run_<name>() { ... }` function
2. Strip the `#!/bin/bash` shebang from each inlined body
3. Strip the `set -euo pipefail` from each inlined body (the subshell wrapper handles this)
4. Remove duplicate `detect_distro` / `check_root` calls — these are hoisted to shared helpers
5. Replace hardcoded variable references with the combined script's `OPERATOR CONFIG` vars
6. Keep all `install_deps`, distro-branching, and core logic exactly intact — no functional changes

---

## Known Constraints

| Module | Constraint |
|--------|-----------|
| `rootkit` | Kernel headers matching running kernel must be installed; Secure Boot must be OFF |
| `rootkit` | x86-64 only; ARM targets will fail at compile |
| `process_inject` | gcc required; x86-64 only (shellcode is x64) |
| `process_inject` | Requires a live listener on `ATTACKER_IP:PTRACE_PORT` before module runs |
| `docker_poisoner` | Requires internet access if Docker is not pre-installed |
| `software_deploy` | Requires internet access for omnitruck install if Chef absent |
| `preosboot` | Requires `update-initramfs` (Ubuntu) or `dracut` (RHEL/Fedora) |
| `antiforensics` | Must run LAST; running it earlier destroys evidence of what's still pending |
| `antiforensics` | Requires `VANISHINGACT_PASSPHRASE` to match hardcoded value |

---

## Interactive Menu Mockup

```
╔══════════════════════════════════════════════════════════╗
║      CCDC Linux Phase 2 Combined — Module Launcher      ║
╠══════════════════════════════════════════════════════════╣
║  #  Module              Status     MITRE                 ║
║  ─  ──────────────────  ─────────  ──────────────────    ║
║  1  rootkit             SUCCESS    T1014                 ║
║  2  docker_poisoner     PENDING    T1525                 ║
║  3  preosboot           PENDING    T1542.001             ║
║  4  process_inject      PENDING    T1055.008             ║
║  5  service_sabotage    PENDING    T1489                 ║
║  6  software_deploy     FAILED     T1072                 ║
║  7  traffic_signal      PENDING    T1205.001             ║
║  8  antiforensics       PENDING    T1070                 ║
╠══════════════════════════════════════════════════════════╣
║  a  Run ALL (recommended order)                         ║
║  r  Resume (skip SUCCESS, retry FAILED)                 ║
║  s  Status only                                         ║
║  q  Quit                                                ║
╚══════════════════════════════════════════════════════════╝
Select module(s) [1-8, a, r, s, q]:
```

---

## Implementation Checklist

- [ ] Write `CCDC_Linux_COMBINED.sh` skeleton with shared helpers and arg parser
- [ ] Inline all 8 module functions from individual scripts
- [ ] Wire `OPERATOR CONFIG` block — replace per-script vars with combined-script vars
- [ ] Implement state file read/write helpers
- [ ] Implement `--all` dispatch with correct ordering
- [ ] Implement `--modules` comma-separated dispatch
- [ ] Implement `--status` read-only display
- [ ] Implement `--force` flag
- [ ] Add config validation (abort if any var is still `CHANGEME`)
- [ ] Test: run `--status` before any modules (shows all PENDING)
- [ ] Test: run `--modules rootkit` alone, confirm state file written
- [ ] Test: run `--all`, confirm rootkit-first and antiforensics-last order
- [ ] Test: deliberately fail a module (wrong IP), confirm others continue
