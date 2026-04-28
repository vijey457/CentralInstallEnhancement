# MLCCN_Install_R12.4.1.26 — Parallel Upgrade Logic

**Script:** `MLCCN_Install_R12.4.1.26.pl`  
**Date:** 2026-04-28  
**Author:** Vijay  
**Scope:** Analysis of roadblocks for parallelising the `upgrade` command and documentation of the implemented solution.

---

## 1. Background

The script orchestrates install, upgrade, patch, and lifecycle operations across multiple remote nodes defined in a config file (`-c=config`). Commands listed in `%gParallelCmds` are dispatched simultaneously to all nodes using Perl worker threads; all other commands execute sequentially node by node.

Prior to this change the `%gParallelCmds` set was:

```perl
my %gParallelCmds = map { $_ => 1 }
    qw(install uninstall showreleases start stop restart);
```

The comment above it read:

> *"activate / upgrade — interactive; one answer applies to every node."*

This document records the analysis of whether that constraint is a genuine technical blocker, the roadblocks examined, and the resolution.

---

## 2. Upgrade Execution Flow (Sequential — Before Change)

```
Primary machine (orchestrator)
│
├── handleRemoteOp()
│   ├── setUpServer()              → binds port 12345, spawns acceptAndRecv thread
│   └── [sequential loop]
│       └── startOnMachine()       → per node, one at a time
│           ├── SSH: rm -rf /tmp/.install; mkdir -p /tmp/.install
│           ├── SCP: scp -r <release_dir> <node>:/tmp/.install
│           └── SSH: ./MLCCN_Install_R12.4.1.26 -a=<primary>:12345 upgrade
│
└── acceptAndRecv thread (detached)
    └── while(accept) → serve one node's prompts → close → next
```

On each remote node the script runs:

```
handleLocalStart()
└── connectAndRecv()       → TCP connect back to primary:12345
└── procUpgrade()
    ├── $gIsUpgrade = true
    ├── updateBaseDir()
    └── upgradeMLC()
        ├── getInstalledReleases()
        ├── checkLicense()
        ├── createPolarisUser()
        ├── installSsts()
        ├── configureSsts()
        ├── setupMlcDaemon()
        └── deleteRelease()
```

---

## 3. Roadblock Analysis

### Roadblock 1 — `acceptAndRecv` serves one client at a time

**Code reference:** `sub acceptAndRecv` — inner `while(accept)` loop processes one TCP connection, then closes and loops.

**Concern:** In parallel mode, all N nodes connect to primary port 12345 simultaneously. The server can only serve one at a time.

**Resolution:** The OS listen backlog (set to 5) absorbs the simultaneous connections. Each remote node's upgrade logic — reading the old INI file, licence check, `installSsts`, `configureSsts`, `setupMlcDaemon` — runs freely on the remote machine without needing the socket. The socket is only used when an interactive prompt answer is needed. Since prompt lookups are hash-table reads (microseconds), the serialisation window at the prompt server is negligible. **Not a blocker.**

---

### Roadblock 2 — "One answer applies to every node" (interactive prompts)

**Code reference:** `getPromptInput()` → `%gPromptToInput` → `.prompts` file.

**Concern:** The original intent was that a user types an answer once (e.g., install path, confirm upgrade) and it applies to all nodes. Would parallel dispatch break this?

**Resolution:** `%gPromptToInput` is populated from the `.prompts` file *before* `handleRemoteOp` is called and *before* any worker threads are spawned. The `acceptAndRecv` thread receives a complete snapshot of this hash at creation time.

- **Pre-loaded answers (normal mode):** All nodes immediately receive the correct answer from the hash — no user interaction needed at all.
- **Live interactive answers (no `.prompts` file):** The first node to ask a given prompt causes `acceptAndRecv` to read from `STDIN` and cache the answer in its local copy of `%gPromptToInput`. Every subsequent node asking the same prompt gets the cached answer — the terminal prompt appears exactly once. This is "one answer applies to every node", working correctly in parallel.

**Not a blocker.**

---

### Roadblock 3 — Global state mutations (`$gIsUpgrade`, `$gBasePath`, `%gPltSstDetail`, etc.)

**Code reference:** `procUpgrade()` sets `$gIsUpgrade = true`, `$gActiveBinDir`; `upgradeMLC()` sets `$gPltSstDetail{'Instance'}`, `$gBasePath`-derived paths.

**Concern:** These are package-level globals. Writing them from concurrent threads would be a race condition.

**Resolution:** These mutations happen inside `procUpgrade()` / `upgradeMLC()`, which run on the **remote machine** inside an SSH subprocess — a completely separate OS process from the orchestrator. The orchestrator's `startOnMachine` worker threads only issue SSH and SCP calls via `executeRemoteCmd()`; they never call `procUpgrade()` or touch any of these globals directly. **No thread-safety issue on the orchestrator.**

---

### Roadblock 4 — No `transferinstall` flag in `upgradeCmdData`

**Code reference:** `%upgradeCmdData` has no `"transferinstall"` key (unlike `activate` or `uninstall`).

```perl
my %upgradeCmdData = (
    "function"   => \&procUpgrade,
    "root"       => true,
    "connection" => true,
    "status"     => true,
);
```

**Concern:** Because `transferinstall` is absent (falsy), `startOnMachine` takes the `scp -r $gLDirPath` branch — copying the **entire release directory** to each node. With N nodes in parallel this means N simultaneous large SCPs outbound from the primary machine.

**Resolution:** This is a **network and disk I/O load concern**, not a correctness issue. For 2–3 nodes it is acceptable. For larger deployments, consider introducing a `transferinstall` flag for upgrade (copy only the installer script and supply a pre-staged package path) or staggering SCP starts. **Not a correctness blocker; documented as a scalability consideration.**

---

### Roadblock 5 — Status file concurrent writes

**Code reference:** `updateStatusFile()` — writes `$ipaddr@status` entries to `.status_upgrade`.

**Concern:** Multiple threads writing to the same status file simultaneously could corrupt it.

**Resolution:** `updateStatusFile()` acquires `$gStatusFileMutex` (a `:shared` variable used with `lock()`) before every read-modify-write cycle. Concurrent writes are fully serialised. **Not a blocker.**

---

### Roadblock 6 — Log file interleaving

**Code reference:** `startOnMachine()` — each thread opens the shared log file with `open($logfd, ">>", $logFile)`.

**Concern:** Multiple threads writing to the same log file could produce interleaved or corrupted lines.

**Resolution:** On Linux, `write()` system calls with `O_APPEND` are atomic at the kernel level for individual calls. Lines from different nodes may appear interleaved in time order, but no data is lost or corrupted. The node name and IP in every log line make the output traceable per node. **Acceptable.**

---

### Roadblock 7 — `$gPeerSockFd` socket handle shared across threads

**Code reference:** `my $gPeerSockFd;` — package-level, used in `acceptAndRecv` (accepted client socket) and in `connectAndRecv` on peer nodes.

**Concern:** In Perl threads non-shared variables are *copied* per thread, not truly shared. But `$gPeerSockFd` appears in multiple contexts.

**Resolution:**
- `acceptAndRecv` runs in one detached thread and uses its own copy of `$gPeerSockFd` to hold the currently accepted client socket. It is the only writer in that thread.
- `connectAndRecv` runs inside the SSH process on the remote machine — a completely separate OS process. It uses its own `$gPeerSockFd` which has no relation to the orchestrator's copy.
- `startOnMachine` worker threads never touch `$gPeerSockFd`.

**No conflict.**

---

## 4. Summary of Roadblocks

| # | Roadblock | Blocker? | Resolution |
|---|-----------|----------|------------|
| 1 | `acceptAndRecv` single-client prompt server | No | Listen backlog queues connections; prompt window is microseconds |
| 2 | Interactive prompts — one answer per node | No | `%gPromptToInput` pre-loaded before threads; `acceptAndRecv` caches first live answer |
| 3 | Global state mutations (`$gIsUpgrade`, etc.) | No | Mutations happen in remote SSH subprocess, not in orchestrator threads |
| 4 | Full `scp -r` to all nodes in parallel | Scalability only | Acceptable for ≤3 nodes; consider staged SCP for larger deployments |
| 5 | Status file concurrent writes | No | Protected by `$gStatusFileMutex` |
| 6 | Log file line interleaving | No | O_APPEND atomicity; lines traceable by node name |
| 7 | `$gPeerSockFd` socket handle | No | Per-thread copy; remote peer runs in a separate OS process |

---

## 5. Implementation

### 5.1 Backup taken before change

```
MLCCN_Install_R12.4.1.26_pre_parallelupgrade_2026-04-28.pl
```

### 5.2 Change made — `%gParallelCmds`

**Before:**

```perl
# Commands dispatched in parallel to all nodes in the config file.
# patch* / activate / upgrade are intentionally kept sequential:
#   patch  - has ordered global-pre / per-node / global-post phases.
#   activate / upgrade - interactive; one answer applies to every node.
my %gParallelCmds = map { $_ => 1 }
    qw(install uninstall showreleases start stop restart);
```

**After:**

```perl
# Commands dispatched in parallel to all nodes in the config file.
# patch* / activate are intentionally kept sequential:
#   patch    - has ordered global-pre / per-node / global-post phases;
#              parallelising the per-node step while sharing pre/post
#              state is not safe.
#   activate - transferinstall=true; prompt answers apply to every node
#              and the interactive session must be kept linear.
# upgrade is now parallel: prompt answers are pre-loaded from .prompts
# before threads are spawned, acceptAndRecv caches the first live answer
# so every subsequent node reuses it, and startOnMachine already handles
# status tracking, failure cleanup, and Ctrl+C cleanup correctly.
my %gParallelCmds = map { $_ => 1 }
    qw(install uninstall showreleases start stop restart upgrade);
```

### 5.3 Why `patch` and `activate` remain sequential

**`patch`** uses sub-commands `patch_global_pre → patch → patch_global_post`. The global-pre and global-post phases carry shared state that must complete across all nodes before the next phase begins. Parallelising the per-node `patch` step while coordinating the pre/post phases would require a barrier mechanism that does not currently exist in the script.

**`activate`** has `transferinstall=true` (copies only the installer script, not the full release) and relies on a strictly linear interactive session where the user confirms activation. It is kept sequential until a prompt-barrier design is implemented.

---

## 6. Parallel Upgrade Execution Flow (After Change)

```
Primary machine (orchestrator)
│
├── handleRemoteOp()
│   ├── setUpServer()                   → binds port 12345, spawns acceptAndRecv thread
│   └── [parallel dispatch — one thread per node]
│       ├── Thread: startOnMachine(OLGW)
│       │   ├── SSH: rm -rf /tmp/.install; mkdir -p /tmp/.install
│       │   ├── Register OLGW in %gRemoteCleanupUid / %gRemoteCleanupPassword
│       │   ├── SCP: scp -r <release_dir> OLGW:/tmp/.install
│       │   ├── SSH: ./MLCCN_Install_R12.4.1.26 -a=<primary>:12345 upgrade
│       │   ├── Cleanup: SSH rm -rf /tmp/.install
│       │   └── Deregister OLGW from cleanup maps
│       ├── Thread: startOnMachine(PRGW)   [same steps, concurrent]
│       └── Thread: startOnMachine(LMF)    [same steps, concurrent]
│
├── join all threads, collect failure count
│
└── acceptAndRecv thread (detached)
    └── while(accept)
        ├── Serve OLGW prompts (hash lookup, ~microseconds) → close
        ├── Serve PRGW prompts (cached answer from OLGW) → close
        └── Serve LMF  prompts (cached answer from OLGW) → close
```

---

## 7. Scalability Consideration

For deployments with more than 3–4 nodes, the simultaneous `scp -r` of the full release directory from the primary machine can saturate the network interface or disk. If this becomes a bottleneck, the recommended approach is to add `"transferinstall" => true` to `%upgradeCmdData` and adapt the SCP step to transfer only the installer script — with the release package pre-staged on each node via a separate distribution mechanism before the upgrade run.
