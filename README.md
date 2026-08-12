# RENE-daq-rcterm

Text-mode (headless) run control for the **RENE / CUPDAQ** data acquisition
system, written in **C++17 on CERN ROOT**.

This is a re-implementation of `DAQ_cup/DAQRC/rc.py` from
[Sang-Yong/RENE-daq](https://github.com/Sang-Yong/RENE-daq) with the PyQt5 GUI
removed, so that the DAQ can be driven entirely from scripts, cron jobs or
systemd units, and can run unattended for weeks.

한국어 문서: **[README.ko.md](README.ko.md)** · 운용 매뉴얼: [docs/MANUAL.md](docs/MANUAL.md)

---

## 1. What this actually is

`rc.py` never touched the hardware. Hardware control lives in the CUPDAQ
binaries (`daq`, `merger`, `tcb`). `rc.py` only did three things:

| Role | Mechanism |
|---|---|
| **Boot** | parse `SERVER` lines from the config file, launch `executedaq.sh` once per node |
| **Control** | send 32-byte commands to the TCB TCP socket (`localhost:7809`) |
| **Monitor** | poll each DAQ socket for event counts and elapsed time |

`rcterm` reproduces exactly those three roles. **No hardware driver code was
rewritten**, which is why this port is low risk.

Two independent executables are produced:

| Binary | Responsibility |
|---|---|
| **`rcterm`** | one run-control session: boot -> configure -> start -> monitor -> end -> exit |
| **`rcsupervisor`** | rotates runs every N hours and restarts the DAQ automatically when it detects a fault |

---

## 2. Repository layout

```
RENE-daq-rcterm/
├── CMakeLists.txt                          build (ROOT Core/RIO/Tree only)
├── build.sh                                one-shot build helper
├── README.md / README.ko.md
├── src/
│   ├── OnlConsts.hh       2.3 kB   protocol constants, mirrors onlconsts.py
│   ├── OnlSocket.hh       4.7 kB   32-byte message socket client (header-only)
│   ├── RunControl.hh      4.7 kB   RunControl / DaqNode / TrgStat declarations
│   ├── RunControl.cc     39.5 kB   config parsing, state machine, DB, output
│   ├── rcterm.cc          8.0 kB   main() of rcterm
│   └── rcsupervisor.cc   23.9 kB   main() of rcsupervisor (self-contained)
├── config/
│   ├── rcterm.params.example
│   ├── rcsupervisor.params.example
│   └── SERVER-block.example            dual-merger SERVER block template
├── scripts/
│   ├── killdaq.sh                      emergency cleanup of daq/merger/tcb
│   └── rcsupervisor.service.example    systemd unit template
└── docs/
    └── MANUAL.md                       detailed operating manual
```

### 2.1 Internal dependency graph

```
OnlConsts.hh        leaf - no project dependency, no ROOT dependency
     ▲
OnlSocket.hh        header-only; OnlConsts.hh + POSIX sockets
     ▲
RunControl.hh       OnlSocket.hh + TString.h
     ▲
     ├── RunControl.cc      + TFile, TTree, TNamed, TSystem
     ├── rcterm.cc          + TSystem
     └── rcsupervisor.cc    OnlConsts.hh + OnlSocket.hh ONLY
                            (deliberately does NOT include RunControl.hh)
```

`rcsupervisor` does **not** compile or link `RunControl.cc`. It needs only the
protocol constants and the socket client, so a defect in the run-control state
machine cannot take the supervisor down with it. This is intentional isolation:
the watchdog must be simpler than the thing it watches.

### 2.2 Translation unit / link map

| Target | Sources | ROOT libs |
|---|---|---|
| `rcterm` | `rcterm.cc`, `RunControl.cc` | Core, RIO, Tree |
| `rcsupervisor` | `rcsupervisor.cc` | Core |

`rcsupervisor` currently links the full `root-config --libs` set for build
simplicity; it only actually uses `TString`/`gSystem`. See §9.11.

---

## 3. Dependencies

### 3.1 Build-time (required)

| Component | Version tested | Used for | If missing |
|---|---|---|---|
| **CERN ROOT** | 6.2x or newer | `TFile`/`TTree` monitor output, `TString`, `gSystem` | build fails |
| **GCC** | 11.5.0 (Rocky 9.8); also verified with 14.2.0 | C++17 | — |
| **CMake** | >= 3.16 (tested 3.31.8) | build driver | use the manual `g++` line in §4.3 |
| **glibc / POSIX** | any modern | sockets, `fork`, `waitpid`, `signal`, `rename` | — |

ROOT components used: **`Core`, `RIO`, `Tree` only.** No `Gui`, no `Gpad`,
no `Graf`, no Cling dictionaries, no `ROOT::Math`. A headless or minimal ROOT
build is sufficient.

### 3.2 Runtime only (not needed to build)

| Component | Used for | If missing |
|---|---|---|
| `sqlite3` CLI | run-number allocation from `runcatalog.db` | fall back to `--no-db --run N` |
| `executedaq.sh` + `daq` / `merger` / `tcb` | the actual DAQ | nothing works |
| `pkill`, `kill` | supervisor forced-recovery path | recovery degrades to SIGTERM only |
| `cp` | staging the config into `$RAWDATA_DIR/CONFIG` | boot fails |

Install the SQLite CLI on Rocky Linux 9 with:

```bash
sudo dnf install -y sqlite
```

### 3.3 Dependencies deliberately removed

| Removed | What it was used for | Replacement |
|---|---|---|
| **PyQt5** | the entire GUI | terminal screen refresh, or `--quiet` one-line log |
| **pydblite** | run-number allocation | `sqlite3` CLI + `last_insert_rowid()` |
| **Python 3** | everything | not required at runtime at all |
| **ssh / scp** | booting remote nodes | local `cp` + `gSystem->Exec` (single-PC site) |

Dropping PyQt5 is the single biggest practical win. PyQt5 is awkward to install
on Rocky Linux 9, and a GUI toolkit has no business being a hard dependency of
an unattended data acquisition system.

The ssh/scp path was removed because the site constant `kISREMOTEDAQ` is
`False`: every node is `localhost`. If the site ever grows to multiple hosts,
see §9.12.

### 3.4 SQLite schema compatibility

`pydblite.sqlite` stores ordinary SQLite tables, so the C++ side is schema
compatible with the existing catalog. Verified against
`create_runcatalog_db.py`:

```sql
CREATE TABLE runcatalog (
  runnum  INTEGER PRIMARY KEY AUTOINCREMENT,   -- rowid alias
  runtype TEXT, rundesc TEXT, shift TEXT, config TEXT,
  stime TEXT, etime TEXT,
  onlbit INTEGER, offbit INTEGER, runlog TEXT
  -- nfadc/tfadc, nsadc/tsadc, niadc/tiadc exist ONLY if the DB was
  -- created with the -f / -s / -i options
);
```

Because `runnum` is `INTEGER PRIMARY KEY`, it *is* the rowid. Therefore
`INSERT ...; SELECT last_insert_rowid();` returns exactly the value that
`pydblite`'s `table.insert()` returned, so run numbering stays continuous with
runs taken using the old GUI.

`rcterm` runs `PRAGMA table_info(runcatalog)` at startup and writes only the
columns that actually exist, so a catalog created without `-f`/`-s` will not
produce SQL errors.

---

## 4. Build

### 4.1 Quick

```bash
git clone https://github.com/Sang-Yong/RENE-daq-rcterm.git
cd RENE-daq-rcterm
source /opt/root/bin/thisroot.sh      # adjust to your ROOT installation
./build.sh                            # -> install/bin/{rcterm,rcsupervisor}
```

### 4.2 CMake by hand

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PWD/install
cmake --build build -j$(nproc)
cmake --install build
```

### 4.3 Without CMake

```bash
g++ -std=c++17 -O2 -Wall -Isrc -o rcterm \
    src/rcterm.cc src/RunControl.cc $(root-config --cflags --libs)
g++ -std=c++17 -O2 -Wall -Isrc -o rcsupervisor \
    src/rcsupervisor.cc $(root-config --cflags --libs)
```

---

## 5. Quick start

```bash
cp config/rcterm.params.example       config/rcterm.params
cp config/rcsupervisor.params.example config/rcsupervisor.params
vi config/rcterm.params        # shift, config, onldaqdir, rawdatadir, heartbeat

# 1) ALWAYS dry-run first. Prints every command and every SQL statement,
#    touches no hardware, writes nothing.
install/bin/rcterm --params config/rcterm.params --dry-run

# 2) short rotation test: 5-minute runs, 2 cycles, 1-minute diagnosis period
install/bin/rcsupervisor --params config/rcsupervisor.params \
    --run-length 0.0833 --margin 2 --check-period 60 --stall-grace 120 --max-cycles 2

# 3) production: 24 h rotation, unlimited cycles
tmux new -s daq
install/bin/rcsupervisor --params config/rcsupervisor.params
```

> **The `heartbeat` path must be identical in `rcterm.params` and
> `rcsupervisor.params`.** If they differ, the supervisor sees a permanently
> stale heartbeat and restarts the DAQ forever. This is the single most likely
> configuration mistake.

---

## 6. `rcterm` options

Precedence: **command line / `--params` file > environment variable > compiled-in
default**. Inside a `--params` file the leading `--` is omitted and the syntax is
`key = value`, with `#` starting a comment.

### 6.1 Run definition

| Option | Meaning | Default |
|---|---|---|
| `--shift NAME` | shift / operator name recorded in the catalog | — |
| `--runtype TYPE` | `physics` / `calibration` / `test` | `test` |
| `--desc "TEXT"` | free-text run description | — |
| `--config FILE` | DAQ config file containing the `SERVER` lines | — |
| `--split-time MIN` | subrun split period in **minutes**, passed to TCB as `-p <seconds>` | 1 |
| `--no-tcb-split` | do not pass `-p` at all (for older TCB binaries) | off |
| `--run-length HOUR` | length of one run before rotation | 24 |
| `--max-runs N` | number of rotation cycles, `0` = unlimited | 0 |
| `--badrun` | mark the run as bad (`onlbit = 0`) | good |
| `--merger-type KIND` | force the merger ADC kind when the node name is ambiguous | auto |

### 6.2 Catalog database

| Option | Meaning |
|---|---|
| `--dbfile FILE` | path to `runcatalog.db` |
| `--no-db` | do not touch the catalog at all |
| `--run N` | explicit run number, required together with `--no-db` |

### 6.3 Site paths and endpoints

| Option | Environment variable | Meaning |
|---|---|---|
| `--onldaqdir DIR` | `ONLDAQ_DIR` | DAQ install prefix, must contain `bin/` |
| `--rawdatadir DIR` | `RAWDATA_DIR` | raw data root; `LOG/` and `CONFIG/` are created under it |
| `--bindir DIR` | — | override the binary directory (default `$ONLDAQ_DIR/bin`) |
| `--exescript NAME` | — | boot script name (default `executedaq.sh`) |
| `--daqserver IP` | `DAQSERVER_IP` | TCB host (default `localhost`) |
| `--daqport N` | `DAQSERVER_PORT` | TCB port (default `7809`) |
| — | `RUNCATALOG_DB` | default value of `--dbfile` |

### 6.4 Output and diagnostics

| Option | Meaning |
|---|---|
| `--update SEC` | screen / heartbeat refresh period |
| `--quiet` | one line per update instead of a full-screen refresh (use for logging) |
| `--log FILE` | append the text log to a file |
| `--rootout FILE` | write the `daqmon` `TTree` to a ROOT file |
| `--heartbeat FILE` | write the machine-readable status file consumed by `rcsupervisor` |
| `--boot-timeout SEC` | how long to wait for all nodes to reach *Booted* |
| `--state-timeout SEC` | how long to wait for any other state transition |
| `--dry-run` | print all commands and SQL, execute nothing |
| `--params FILE` | load options from a file |
| `-h`, `--help` | usage |

`rcterm` returns **exit status 1** when option parsing or `Init()` fails, and
**0** on a clean finish. `rcsupervisor` relies on this to tell a bad
configuration apart from a normal end of run.

### 6.5 GUI to CLI mapping

| `rc.py` widget | `rcterm` equivalent |
|---|---|
| `ShiftConfig` | `--shift NAME` |
| `RunTypeConfig` | `--runtype ...` |
| `RunDescConfig` | `--desc "TEXT"` |
| `ConfigFileButton` | `--config FILE` |
| `SplitTimeConfig` | `--split-time MIN` |
| Boot / Config / Start / End / Exit buttons | performed automatically in sequence |
| GOODRUN confirmation dialog | `--badrun` |
| — (new capability) | `--run-length`, `--heartbeat`, `--rootout`, `--dry-run` |

### 6.6 Monitor `TTree` (`--rootout`)

Tree name `daqmon`, one entry per update:

| Branch | Type | Meaning |
|---|---|---|
| `ctime` | `Double_t` | UNIX time of the sample |
| `run`, `subrun` | `Int_t` | run / subrun number |
| `state` | `Int_t` | decoded DAQ state index |
| `daqtime` | `Double_t` | DAQ-reported elapsed time [s] |
| `ndaq` | `Int_t` | number of monitored nodes |
| `nev[ndaq]` | `Long64_t` | cumulative event count per node |
| `srate[ndaq]` | `Double_t` | instantaneous rate [Hz] |
| `arate[ndaq]` | `Double_t` | average rate since run start [Hz] |

Node names are stored alongside as a `TNamed` object called `daqnames`, so the
branch index can be mapped back to a node name offline.

---

## 7. `rcsupervisor`

### 7.1 Control flow

```
rcsupervisor
  ├─ fork/exec rcterm with:  --params <rcterm-params>
  │                          --max-runs 1
  │                          --run-length (run-length + margin)
  │                          --quiet
  │                          --heartbeat <path>
  │                          [--no-db --run N]   only when --no-db is set
  │                          [everything after `--` on the command line]
  ├─ at exactly run-length, send SIGTERM to the rcterm PID only
  │     └─ rcterm performs ENDRUN -> RUNENDED -> EXIT, finalises the catalog row
  ├─ when the child exits, start the next cycle with a fresh run number
  └─ every --check-period, run the 5-point diagnosis; recover if it fails
```

The child is given `--run-length` = requested length **plus** `--margin`, and
the supervisor terminates it at the requested length. The margin exists so that
the *supervisor* decides when the run ends; `rcterm`'s own timer is only a
backstop in case the supervisor dies.

### 7.2 Who allocates the run number

**`rcsupervisor` never touches the database.** It contains no SQL and does not
invoke `sqlite3`. Each freshly started `rcterm` allocates its own run number by
inserting a catalog row and reading `last_insert_rowid()`. The supervisor only
supplies an explicit `--run N` when running in `--no-db` mode, incrementing the
number itself for each cycle.

Consequence: the DB path, shift, run type, split time and all other run
properties are configured in the **`rcterm` params file**, not in the
supervisor's. The supervisor deliberately has no `--shift`, `--config`,
`--split-time`, `--dbfile`, `--onldaqdir` or `--rawdatadir` options.

### 7.3 Signal policy (important)

SIGTERM is sent to the **`rcterm` PID only, never to the process group.**
`executedaq.sh` backgrounds `daq`, `merger` and `tcb` into the same process
group; signalling the group would kill the DAQ mid-write and corrupt the last
raw file. On the normal path `rcterm` shuts the DAQ down cleanly with the `EXIT`
command. Forced termination (`SIGKILL` to the group, then `pkill`) is used
**only** on the recovery path, after the clean path has already failed.

### 7.4 Heartbeat file format

`rcterm --heartbeat FILE` writes to a temporary file and then `rename()`s it, so
a reader never observes a partially written file.

```
time=1786554086       # wall clock of this sample; if stale, rcterm is stuck
phase=running         # booting|booted|configured|running|ending|ended|error|failed|notrunning
run=123
subrun=45
state=Running
statebit=3
error=0
status=8
daqtime=1234.5
totev=98765           # global event sum, used for stall detection
ndaq=2
daq0=FADCDAQ n=98700 sr=321.4 ar=320.6
daq1=SADCDAQ n=65 sr=4.6 ar=4.6
```

### 7.5 Five-point diagnosis

Any single failing check marks the DAQ abnormal.

| # | Check | Abnormal when | Disable with |
|---|---|---|---|
| 1 | heartbeat freshness | older than `--stale-limit` (300 s) | — |
| 2 | `error=` field | equals 1 | — |
| 3 | `phase` / `state` consistency | not *Running* | — |
| 4 | direct TCB socket query | connect fails, no reply, ERROR bit set, or not running | `--no-socket-check` |
| 5 | `totev` growth | flat for `--stall-grace` (1800 s) | `--no-stall-check` |

Checks 3 to 5 are suppressed during `--boot-grace` (300 s) after each start, so
normal boot latency is not mistaken for a fault.

### 7.6 Recovery sequence

```
1) SIGTERM to the rcterm PID              clean shutdown attempt, catalog updated
2) not gone within --grace (180 s)        SIGKILL to the process group
3) pkill -f "<bindir>/{tcb,merger,daq}"   SIGTERM, then SIGKILL for stragglers
4) wait --settle (10 s)
5) wait --backoff (30 s), restart with a new run number
```

After `--max-consec-fail` consecutive failed cycles (default 5) the supervisor
exits instead of mass-producing junk runs. A successful cycle resets the
counter.

### 7.7 `rcsupervisor` options

| Option | Meaning | Default |
|---|---|---|
| `--rcterm PATH` | path to the `rcterm` binary | `./rcterm` next to the supervisor |
| `--rcterm-params FILE` | params file handed to `rcterm` | — |
| `--run-length HOUR` | rotation period | 24 |
| `--margin MIN` | extra `--run-length` given to the child as a backstop | 30 |
| `--max-cycles N` | number of cycles, `0` = unlimited | 0 |
| `--max-runs N` | alias of `--max-cycles` | 0 |
| `--check-period SEC` | diagnosis period | 600 |
| `--stale-limit SEC` | heartbeat staleness threshold | 300 |
| `--boot-grace SEC` | grace period after each start | 300 |
| `--stall-grace SEC` | how long `totev` may stay flat | 1800 |
| `--no-stall-check` | disable check 5 | off |
| `--no-socket-check` | disable check 4 | off |
| `--grace SEC` | wait before escalating SIGTERM to SIGKILL | 180 |
| `--settle SEC` | wait after cleanup | 10 |
| `--backoff SEC` | wait before restarting | 30 |
| `--max-consec-fail N` | give up after this many consecutive failures | 5 |
| `--heartbeat FILE` | heartbeat path, **must match the `rcterm` params file** | — |
| `--bindir DIR` | binary directory used to build the `pkill` patterns | — |
| `--daqserver IP`, `--daqport N` | TCB endpoint for check 4 | localhost:7809 |
| `--no-db` | supervisor allocates run numbers itself via `--run` | off |
| `--run N` | first run number in `--no-db` mode | — |
| `--log FILE`, `--quiet`, `--dry-run`, `--params FILE`, `-h` | as for `rcterm` | — |

Anything after a bare `--` is passed through to `rcterm` verbatim, which is the
escape hatch for options the supervisor does not know about:

```bash
rcsupervisor --params config/rcsupervisor.params -- --rootout /Data/LOG/mon.root
```

---

## 8. Bugs found in the original `rc.py`, avoided here

All of these were found by reading the upstream sources and are corrected in
`rcterm`.

1. **`SplitTimeConfig.setText(self.SplitTime)`** passes an `int` to a method
   that requires `str`, raising `TypeError`. The initial value (60) is also
   inconsistent with the label, which claims 1 minute.
2. **Boot ordering breaks as soon as AMOREADC is used.** `sortfunc(e)` returns
   `e[2]`, which is the `dopt` string, not the node name. TCB's `dopt` begins
   with `-d`, so `pop(0)` happens to move TCB last, which looks correct. But
   AMOREADC's `dopt` begins with `-a`, and `'a' < 'd'`, so **AADC is moved last
   instead of TCB** and the TCB is booted before its clients. `rcterm` orders
   nodes by node mode (`MERGER -> ADC -> TCB`), never by string comparison.
3. **A node named `MERGER` is misclassified as MADC.** `rc.py` derives the ADC
   letter from `name[0].lower()`; for `MERGER` that yields `m`, i.e. `-m`
   (MADC). `rcterm` matches ADC kind by substring
   (`FADC`, `SADC`, `IADC`, `GADC`, `AMOREADC`, `MADC`), so `FADCMERGER` maps to
   `-f` and `SADCMERGER` maps to `-s`.
4. **The pre-existing text mode `rcterm.py` cannot run at all.** It calls
   `onlutils.send_message()` and `onlconsts.kSOFTWARE_VER`, neither of which
   exists in the current sources; it launches `executenulldaq.sh` instead of
   `executedaq.sh`; and it never passes the split time. It was not reusable.
5. **Comment contradicts the code**: `split_time = self.SplitTime * 60` converts
   minutes to seconds, while the comment says `[s] -> [m]`. `executedaq.sh -p`
   takes **seconds**.
6. **`$RAWDATA_DIR/LOG` is never created.** `executedaq.sh` redirects stdout and
   stderr into that directory; if it does not exist the DAQ dies silently with
   no diagnostic anywhere. `rcterm` creates `$RAWDATA_DIR/LOG` and
   `$RAWDATA_DIR/CONFIG` with `mkdir -p` before booting.

### 8.1 Config validation performed by `rcterm`

| Situation | Action |
|---|---|
| ADC node name contains no recognisable ADC kind | **fatal** |
| merger name has no ADC kind and the config has 2+ ADC kinds | **fatal**, asks for a rename or `--merger-type` |
| merger name has no ADC kind and the config has exactly 1 ADC kind | inferred, logged |
| two mergers of the same ADC kind | **fatal** |
| merger has no matching ADC | warning, and `-x` is not attached |
| the same `ip:port` used by two nodes | **fatal** |
| merger port is 22 | warning (that is the SSH port) |

`-x` is attached to an ADC only when a merger of the *same* ADC kind exists, so
an ADC is never told to forward data to a merger that is not running.

---

## 9. Known limitations and required improvements

Listed honestly, highest impact first.

**9.1 Not yet verified on real hardware. This is the highest remaining risk.**
The build is clean and the boot-command generation has been verified with
`--dry-run`, but no run has been taken on the real DAQ. Before production use:
run `--dry-run`, then a two-cycle short test, then watch one full rotation.

**9.2 Inter-run dead time is not zero, roughly 10 to 40 s.** The protocol has
only `CONFIGRUN`, `STARTRUN`, `ENDRUN` and `EXIT`; there is no command to change
the run number of a running system. The run number is fixed when
`executedaq.sh -r <run>` starts the processes, so rotation requires a process
restart. The measured dead time is logged for every cycle. If zero dead time is
mandatory, do not rotate runs at all and rely on subruns instead:
`--max-runs 1 --run-length 8760 --split-time 1`.

**9.3 `sqlite3` is invoked as a subprocess rather than linked.** `RunSQL()`
writes a temporary SQL file and shells out. Quotes in `--desc` are escaped, but
that is weaker than parameter binding, and it costs one process spawn per run.
Improvement: link `libsqlite3` and use prepared statements.

**9.4 Rates are derived from the DAQ-reported elapsed time, not the wall
clock.** If the DAQ's nanosecond counter stalls, the instantaneous rate becomes
undefined rather than dropping to zero, which slightly weakens stall detection.
Improvement: compute a second rate from wall clock and compare the two.

**9.5 Monitor sockets are opened once per run and never re-opened.** If an ADC
monitor socket drops mid-run its counters freeze until the next cycle. The DAQ
itself keeps running, so this is a monitoring defect rather than a data defect.
Improvement: reconnect periodically on failure.

**9.6 The socket timeout is a hard-coded 3 s** in `OnlSocket::Connect()`. On a
heavily loaded machine a legitimate reply can exceed that and be misread as a
fault. Improvement: expose it as an option.

**9.7 The heartbeat file has no locking.** The `rename()` write is atomic, which
is enough for a single reader, but nothing prevents two `rcterm` instances from
sharing one path and confusing the supervisor. Improvement: a PID file plus
`flock`, and have the supervisor verify the PID it is watching.

**9.8 No automated tests.** Config parsing, merger-kind resolution and bitmask
decoding are pure functions and easy to test. Improvement: add a `tests/` target
with a few golden `SERVER` blocks and expected boot command lines.

**9.9 The catalog row is inserted before the run is known to be good.** If boot
fails, a row remains with an empty `etime`. Improvement: mark such rows
explicitly as aborted.

**9.10 State-machine timeouts are fixed per transition.** A slow FADC firmware
load can exceed `--boot-timeout` even though it would have succeeded. The
remedy today is to raise the value manually.

**9.11 `rcsupervisor` links more of ROOT than it needs.** It uses only
`TString` and `gSystem`; it could be built with no ROOT dependency at all, which
would let the watchdog survive a broken ROOT installation. Improvement: replace
the two ROOT uses with `std::string` and `std::system`.

**9.12 Single-host only by design.** All ssh/scp handling was removed because
`kISREMOTEDAQ` is `False`. If the site ever spans multiple hosts, the boot and
config-staging steps must be reintroduced as remote calls; the monitoring and
control paths already work over TCP and need no change.

**9.13 Upstream `test_wj_merger.config` needs two fixes before mergers are
used**: the `MERGER` node listens on port 22, which is the SSH port, and its
name carries no ADC kind. Rename the nodes to `FADCMERGER` and `SADCMERGER` and
correct the ports. `rcterm` catches both problems, one as a warning and one as a
fatal error.

---

## 10. Verification status

| Item | Status |
|---|---|
| Compile with g++ 14.2, `-std=c++17 -Wall -Wextra` | **pass**, zero warnings |
| Link both binaries | **pass** |
| Dual-merger kind resolution (`FADCMERGER` -> `-f`, `SADCMERGER` -> `-s`) | **pass** (`--dry-run`) |
| Boot order `MERGER -> ADC -> TCB` | **pass** |
| `--split-time 1` becomes TCB `-p 60` | **pass** |
| `--no-tcb-split` removes `-p` | **pass** |
| All seven config-validation guards of §8.1 | **pass** |
| `-x` attached only when a same-kind merger exists | **pass** |
| Exit status 1 on fatal init failure | **pass** (source-verified: `if (!rc.Init()) return 1;`) |
| Build and link against real ROOT headers | **not verified** (stub headers were used) |
| Execution against real DAQ hardware | **not verified** |
| `rcsupervisor` rotation and recovery on hardware | **not verified** |

The compile check used stub headers that reproduce the real ROOT signatures,
including the inverted return convention of `TSystem::AccessPathName()` and the
const/non-const overloads of `TObject::Write()`.

---

## 11. License and provenance

Derived from the CUPDAQ / RENE DAQ software in
[Sang-Yong/RENE-daq](https://github.com/Sang-Yong/RENE-daq). The wire protocol
constants in `OnlConsts.hh` mirror `DAQ_cup/DAQRC/onlconsts.py`; follow the
licensing of the parent project.
