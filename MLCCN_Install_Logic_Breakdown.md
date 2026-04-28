# MLCCN_Install Script — Logic Breakdown

**Script:** `MLCCN_Install_R12.4.1.26`  
**Language:** Perl  
**Release:** R12.4.1.26  
**Product:** MLCCN (Multi-Link Call Controller Node) / MER / TSMLCCN

---

## 1. Overview

`MLCCN_Install` is a centralized Perl installation and lifecycle management script for the MLCCN (and related product variants: MER, TSMLCCN) telecom platform. It can be executed locally on a target VM or remotely against one or more VMs by supplying a configuration file via the `-c` switch.

The script manages the full software lifecycle:
- **Install** — deploy software packages and configure subsystems
- **Upgrade** — migrate from an existing release to a new one
- **Patch** — apply incremental binary or configuration patches
- **Activate** — switch the active release symlink to a selected installed release
- **Uninstall** — remove selected or all installed releases
- **Start / Stop / Restart** — control application processes
- **Status** — display process run states
- **Show Releases** — list installed releases and their subsystem components

---

## 2. Script Initialization & Global State

### 2.1 Constants

| Constant | Value | Purpose |
|---|---|---|
| `listen_port` | 12345 | TCP port used for centralized remote operation handshake |
| `mlccn` | `"mlccn"` | Product identifier |
| `mer` | `"mer"` | MER product variant |
| `tsmlccn` | `"tsmlccn"` | TSMLCCN product variant |
| `LOGFATAL` | 1 | Log level: fatal — logs and exits |
| `LOGERROR` | 2 | Log level: error — logs without exit |
| `LOGINFO` | 4 | Log level: informational — file only |
| `LOGCONS` | 8 | Log level: console print only |

### 2.2 Key Global Variables

| Variable | Description |
|---|---|
| `$gProduct` | Detected product name (e.g., `MLCCN`) |
| `$gProductLc` | Lowercase product name |
| `$gProductLegacy` | Legacy product name for upgrade paths (e.g., `MLC`) |
| `$gBaseDir` | Root disk path: `/Disk` |
| `$gHomeDir` | User home: `/Disk/home/polaris` |
| `$gBasePath` | Product home: `/Disk/home/polaris/mlccn` |
| `$gReleasePath` | Release storage: `$gBasePath/release` |
| `$gActiverRelLink` | Symlink pointing to currently active release |
| `$gActiveBinDir` | Bin directory of active release |
| `$gRhelVer` | Detected RHEL version: `6`, `7`, or `0` (legacy) |
| `$gIsLinux` | Boolean: `true` if OS is Linux |
| `$gCentralizedOp` | Boolean: `true` if running as part of a remote dispatch |
| `$gIsUpgrade` | Boolean: set to `true` during upgrade operation |
| `$gUsingOpensaf` | Boolean: `true` if OpenSAF HA framework is in use |
| `$gPeerSockFd` | TCP socket handle for centralized prompt relay |

### 2.3 OS and Kernel Detection

At startup the script queries `uname -r`, `uname -p`, and `uname -s` to detect:
- Linux vs. Solaris
- Kernel major version → maps to RHEL 6, RHEL 7, or pre-RHEL 6
- Host name, processor architecture

Base port assignments differ by product variant:
- Standard MLCCN: `AppMgr` base port = **10000**, node base port = **11000**
- TSMLCCN: `AppMgr` base port = **12000**, node base port = **13000**

Ephemeral port range is set to **50000–65535** to avoid port self-connection (TCP simultaneous open issue).

---

## 3. Subsystem (SST) Registry

The script defines a registry of **subsystems (SSTs)**, each described by a Perl hash containing:

| Key | Description |
|---|---|
| `LicName` | License file identifier for this SST |
| `PkgPrefix` | Prefix of the tar.gz package file |
| `Apps` | Ordered list of application binaries |
| `Configs` | Config files / scripts to symlink without version number |
| `InstallFunc` | Reference to the SST-specific install function |
| `ConfigFunc` | Reference to the SST-specific configure function |
| `Mode` / `Instance` / `PkgName` | Populated at runtime from license data |

### Registered Subsystems

| SST | License Key | Key Applications |
|---|---|---|
| Platform (PLT) | PLT | AppMgr, OamClient, LogsManager, BRM |
| SGW | SGW | SGWApp, M3UA, SIGTRANStack, SS7Stack, etc. |
| MDB | MDB | MdbApp |
| MLS | MLS | MiMSPApp, MiGmlcGw, OamAggregator, etc. |
| PRGW | PRGW | PRGWAgent, STS, SSH, NRPROBE, LTEPROBE, GSMPROBE, ERApp |
| LDS | LDS | LocReqDisp, GsmCallManager, UmtsCallManager, LdsLteCm, etc. |
| OLGW | OLGW | AppServer, LCSI |
| TLR | TLR | TlrApp |
| ADS | ADS | AgpsServer, OtdoaAds |
| ADM | ADM | WLDM, WSDM |
| OAM | OAM | (OAM-only config, no apps) |
| CGW | CGW | CaGwApp |
| HVGW | HVGW | HVlrGwApp |

For the **MER** product variant, only PRGW-MER (`PRGWAgent`, `ERApp`) and Platform (PLT) are included.

---

## 4. Command Dispatch Table

Each supported command is registered in `%installCmds` with metadata:

| Command | Handler Function | Requires Root | Requires TCP Connection | Has Status Tracking |
|---|---|---|---|---|
| `install` | `procInstall` | Yes | Yes | Yes |
| `upgrade` | `procUpgrade` | Yes | Yes | Yes |
| `patch` | `procPatch` | Yes | No | Yes |
| `activate` | `procActivate` | Yes | Yes | Yes |
| `uninstall` | `procUninstall` | Yes | Yes | Yes |
| `start` | `procStart` | Yes | No | Yes |
| `stop` | `procStop` | Yes | No | Yes |
| `restart` | `procReStart` | Yes | No | Yes |
| `status` | `procStatus` | No | No | No |
| `showreleases` | `procShowRel` | Yes | No | No |
| `configure` | `procConfigure` | No | No | No (dev/test only) |

The `patch` command internally expands into three sub-commands: `patch_global_pre`, `patch`, and `patch_global_post` — executed sequentially across all remote VMs.

---

## 5. Execution Flow

### 5.1 Entry Point — `Start()`

```
Start()
 ├── readPrompt()        — parse ARGV into %prompts hash
 ├── Check for -o=abort  — delete .status_<cmd> and .prompts files, then exit
 ├── Check for -c=<file> — CENTRALIZED OPERATION path
 │    ├── Parse config file (Name, IP, Username, Password per line)
 │    ├── Restore prior progress from .status_<cmd> file
 │    ├── Restore prior prompt answers from .prompts file
 │    └── handleRemoteOp() → startOnMachine() for each VM
 └── No -c switch        — LOCAL OPERATION path
      └── handleLocalStart()
```

### 5.2 Local Operation — `handleLocalStart()`

```
handleLocalStart()
 ├── If -a=<ip:port> present → set gCentralizedOp=true, connectAndRecv() (TCP to controller)
 ├── Validate command exists in %installCmds
 ├── If command requires root → checkRootAndExit()
 └── Call command's handler function ($cmdData->{'function'})
```

### 5.3 Remote Operation — `handleRemoteOp()` → `startOnMachine()`

For each target VM defined in the config file:

```
startOnMachine()
 ├── Skip VM if already marked "done" in .status_<cmd>
 ├── SSH: create /tmp/.install directory on remote VM
 ├── SCP: transfer installer (or full directory) to remote /tmp/.install
 ├── SSH: execute installer on remote with -a=<selfIp:port> flag
 │    └── Remote instance calls handleLocalStart() in centralized mode
 ├── If requires TCP connection:
 │    └── setUpServer() — bind TCP socket, spawn acceptAndRecv() thread
 │         └── Relay interactive prompts between controller and remote
 ├── On success: update .status_<cmd> with "done"
 ├── On failure: update .status_<cmd> with "Failed (<reason>)", abort
 └── SSH: cleanup /tmp/.install on remote VM
```

**Resume logic:** If a previous run was aborted mid-way, re-running with `-c=<config>` reads the `.status_<cmd>` file and skips VMs already marked `"done"`, restarting from the last failed VM.

---

## 6. Operation Implementations

### 6.1 Install — `installMlc()`

1. Clean up existing shared memory segments for the AppMgr key.
2. Validate `NodeLicense.lic` via `checkLicense()` — determines which SSTs are licensed and how many instances are permitted.
3. Check release directory for existing installs; abort if this release is already installed or if maximum releases (2) are reached.
4. Create the `polaris` OS user and group if not present (`createPolarisUser()`).
5. Call `installSsts()`:
   - `setupRelease()` — create versioned release directory under `$gReleasePath`
   - `genPort()` — assign unique TCP port numbers to all applications
   - For each licensed SST: `setupSst()` — untar package, create symlinks for binaries and config files in the `bin/` dir, invoke SST-specific install function
   - Copy the install script itself into the release's `package/` dir
   - Register `mlcclean` with `chkconfig`
6. Call `configureSsts()` — invoke each SST's config function, then write `PDEApp.ini`
7. Write `.done` timestamp file to mark the release as completed
8. Setup `mlccdaemon` (PM CLI / daemon service)
9. If this is the first install: auto-activate (create `active` symlink) and setup BRM
10. Set up syslog init (RHEL < 6 only)

### 6.2 Upgrade — `upgradeMLC()`

1. Validate the new release is not already installed.
2. Identify the currently active release directory (`$oldRelDir`) and its `NodeLicense.lic`.
3. Read the previous `PDEApp.ini` to extract existing node configuration.
4. Validate license (checks local directory first for a replacement license file).
5. Remove stale INI parameters that will be regenerated (FaultMonitor sections, etc.).
6. Call `installSsts()` to lay down the new release.
7. Call `configureSsts()` — passing `$oldRelDir` for value migration.
8. Copy the license file to the new release if a local copy was used.
9. Setup `mlccdaemon`.
10. Write `.done` file, log success, print component summary.
11. Prompt user to run `activate` to switch to the new release.
12. Delete any second installed (non-active) release (`deleteRelease()`).

### 6.3 Patch — `patchMlc()`

The patch operation uses an external `patch.ini` configuration file and runs in three stages:

**Stage: `patch_global_pre`**
- Iterates PATCH_1 through PATCH_100 sections in `patch.ini`
- For each patch section, evaluates `check` entries to determine if the patch applies
- Executes `pre-global` actions (commands, start/stop of specific apps)

**Stage: `patch`**
- Re-evaluates checks for each patch section
- Runs pre-machine actions, then `executePatch()`:
  - Untars any `.tar.gz` files in the working directory
  - For `file` type patches: `applyFilePatch()` — replaces binary symlink target, backs up old binary with release suffix, records version in `.patchver`
  - For `ini` type patches: `applyConfigurationPatch()` — adds, modifies, or deletes parameters in `PDEApp.ini` using wildcard section/key matching
- Runs post-machine actions

**Stage: `patch_global_post`**
- Executes `post-global` actions for all applicable patches

### 6.4 Activate — `activateMlc()`

1. Verify AppMgr is not currently running (applications must be stopped).
2. List all installed releases (those with a `.done` marker file).
3. Prompt user to choose which non-active release to activate (auto-selects if only one option).
4. Call `createActiveRelLink()` — removes the old `active` symlink and points it to the chosen release directory.
5. Append an `activate: <timestamp>` entry to `.done`.
6. Remove the old BRM init entry and re-run `setupBRM()`.

### 6.5 Uninstall — `uninstallMlc()`

1. List all installed releases.
2. Prompt the user to choose a specific release or ALL (with confirmation for ALL).
3. For each selected release:
   - If it is the active release: stop all applications (`stopMLCApplication()`), then clear the `active` symlink.
   - Delete the release directory (`deleteRelease()`).
4. If no releases remain after deletion:
   - If OpenSAF was in use: shut down and rpm-remove opensaffire/opensaf packages.
   - Remove daemon, BRM, and AppMgr init/service entries.
   - Clean up CDT, PSD, release, and log paths.

### 6.6 Start — `startForCurrentRelease()`

1. Verify an active release exists.
2. If `-p=<proc1,proc2>` specified: start only the named processes via `startApp`.
3. Otherwise:
   - Setup kernel network parameters (socket buffer sizes, ephemeral port range) via `setupStart()`.
   - **OpenSAF path:** rename opensafd script, call `opensafd start`, unlock any locked-instantiation SUs, handle retry up to 3 times.
   - **Standard path:** read `PDEApp.ini`, setup AppMgr service (`setupAppMgr()`), remove redundancy monitor file.
4. If `.sctp` marker file exists: start SCTP (`/etc/init.d/sctp start`).
5. Setup BRM service.

### 6.7 Stop — `stopForCurrentRelease()`

1. Verify an active release exists.
2. If `-p=<proc1,proc2>` specified: stop only named processes via `startApp`.
3. Otherwise:
   - **OpenSAF path:** lock all SUs, rename opensafd script to prevent respawn, call stop, release virtual IPs, remove SCTP entries.
   - **Standard path:** check if processes are running, write redundancy monitor file, call `startApp stop all`, remove AppMgr init entries, release virtual IPs.
4. Force-kill (`kill -9`) any remaining product processes identified by `ps`.

### 6.8 Restart — `procReStart()`

Calls `stopForCurrentRelease()`, sleeps 1 second, then calls `startForCurrentRelease()`.

### 6.9 Status — `statusForCurrentRelease()`

- **OpenSAF path:** queries `amf-state comp pres` for component presence states; prints `Running` or `Stopped` per component on this node; reports ACTIVE/STANDBY HA state.
- **Standard path:** calls `startApp status all` and displays the output written to `/tmp/.cmdout`.

### 6.10 Show Releases — `showReleases()`

Lists each installed release directory (those with a `.done` file) under `$gReleasePath/RELEASE_R*`. For each:
- Prints whether it is **Active** or **Installed**
- Lists the release directory path
- Lists each SST package and its release number
- Lists any patches applied (from `.patchver` files)

Also reads `NodeLicense.lic` and `PDEApp.ini` to print the full licensed component summary.

---

## 7. Supporting Subsystems

### 7.1 Service Management (RHEL version-aware)

`startService()`, `setupAppMgr()`, `setupMlcDaemon()`, `setupBRM()`, and `removeInitTabEntry()` all branch on `$gRhelVer`:

| RHEL Version | Mechanism |
|---|---|
| 7+ | `systemd` — writes `.service` file to `/usr/lib/systemd/system/`, uses `systemctl enable/start/stop/disable` |
| 6 | `Upstart` — writes `.conf` file to `/etc/init/`, uses `initctl start/stop/reload-configuration` |
| < 6 | `SysV inittab` — modifies `/etc/inittab` directly, calls `init q` to reload |

### 7.2 Port Assignment — `genPort()`

Port numbers are dynamically assigned starting at `$gBasePort + 10` (to leave 10 slots for hard-coded ports). Each application instance gets a unique port number stored in `%gPortNumbers`. Port assignments are written into `PDEApp.ini`.

### 7.3 Logging — `logToFile()`

Every log entry is timestamped and written to:
- **Script log:** `$gBasePath/logs/<product>install.log`
- **Console:** only if `LOGCONS` bit is set or `$logEnabled` env var is `"true"`
- **Color:** fatal/error → red, info → green (ANSI color codes)
- **Remote mode:** fatal messages are wrapped with `FATAL;...FATAL;` delimiters for detection by the centralized controller's `executeRemoteCmd()`.

`LOGFATAL` causes `exit(1)` after logging.

### 7.4 Prompt Relay for Remote Operations

When a command requiring user interaction runs remotely via `-a=<ip:port>`:
- The remote instance connects to the controller's TCP server (`connectAndRecv()`).
- Any call to `getPromptInput()` on the remote side sends the prompt string over the TCP socket.
- The controller's `acceptAndRecv()` thread receives the prompt, looks up a cached answer or reads from STDIN, and sends the answer back.
- Answers are cached in `%gPromptToInput` and persisted to `.prompts` file to support resume.

### 7.5 License Validation — `checkLicense()`

Reads `NodeLicense.lic`, verifies the license against the node configuration, and populates:
- `%configHash` — platform configuration data derived from the license
- `@licssts` — array of SST detail hashes that are enabled under this license

Returns the platform instance count (`$cnt`) which governs how many node instances are configured.

### 7.6 INI File Management

The script implements a custom INI file reader/writer:
- `readIniFile()` — parses `[SECTION]` / `key=value` format into a nested hash
- `writeIniFile()` — serializes the hash back to file
- `getParam()` / `setParam()` / `delParam()` — single-value accessors
- `writeConfigVal()` — conditionally writes only if key is absent (for safe merges during upgrade)

---

## 8. Error Handling and Abort / Resume

- Every `System()` call accepts a `$die` flag. When `$die=1`, failure triggers `LOGFATAL` and exits.
- For centralized multi-VM operations, each VM's progress is tracked in `.status_<cmd>`. On any VM failure, the operation is aborted with an error message and the `.status_<cmd>` file retains the failure reason.
- To **abort** an in-progress operation: `./MLCCN_Install -o=abort <command>` — deletes the status file cleanly.
- To **resume** after fixing an error: re-run `./MLCCN_Install -c=<config> <command>` — skips all VMs marked `"done"`, restarts from the failed VM.
- Signal handlers (`SIGINT`, `SIGTERM`) log `"Operation aborted"` and exit cleanly.

---

## 9. Directory Structure After Install

```
/Disk/home/polaris/mlccn/
 ├── active -> release/MLCCN_RELEASE_R<version>/   (symlink to active release)
 ├── release/
 │    └── MLCCN_RELEASE_R<version>/
 │         ├── bin/           (symlinks to versioned binaries and config files)
 │         ├── lib/           (symlinks to shared libraries)
 │         ├── package/
 │         │    └── PLT_RELEASE_R<ver>/  (untarred subsystem packages)
 │         ├── PDEApp.ini     (generated configuration)
 │         ├── .done          (install/upgrade/activate timestamps)
 │         └── .patchver      (patch version history)
 ├── logs/
 │    ├── mlccninstall.log
 │    ├── LocationResult/
 │    ├── KPI/
 │    ├── PID/
 │    ├── MsgLog/
 │    └── coredump/
 ├── CDTs/  (GSM/, UMTS/, LTE/, NR/)
 └── PSD/   (GSM/, UMTS/, LTE/, NR/)
```

---

## 10. Summary of Key Design Patterns

- **Centralized vs. local mode** is controlled by the presence of `-c` (remote dispatch) or `-a` (remote receiver) switches, enabling the same script to act as both orchestrator and agent.
- **SST plugin architecture** decouples subsystem-specific install/configure logic into per-SST function references (`InstallFunc`, `ConfigFunc`), making it straightforward to add new subsystems.
- **License-driven deployment** — the set of installed components is determined entirely by `NodeLicense.lic`, not by hardcoded lists.
- **Idempotent resume** — status files and `.done` markers allow safe re-runs after partial failures without duplicating work.
- **RHEL version abstraction** — all service lifecycle management is transparently handled for RHEL 6, 7, and legacy SysV systems in a single script.
