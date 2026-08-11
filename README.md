# agenticmode

[![CI](https://github.com/ariakalantari/agenticmode/actions/workflows/ci.yml/badge.svg)](https://github.com/ariakalantari/agenticmode/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Keep a Mac laptop awake with its lid closed until your agent work is done.

`agenticmode` is a dependency-free macOS command-line tool. It can follow exact Codex turns, published OpenCode activity, supported one-shot agent processes, a command you launch, or PIDs you already know. A small root-owned watchdog restores the previous sleep setting when the controller exits—even if that controller is killed.

> [!CAUTION]
> Agentic mode disables system sleep, not just lid-close sleep. Keep the Mac on a hard, ventilated surface, never place it in a bag while active, and use a timeout or battery cutoff for unattended work.

## Get started

### 1. Install

With Homebrew:

```bash
brew tap ariakalantari/agenticmode https://github.com/ariakalantari/agenticmode
brew install ariakalantari/agenticmode/agenticmode
```

Or install directly without a package manager:

```bash
curl -fsSL https://raw.githubusercontent.com/ariakalantari/agenticmode/main/install.sh | /bin/bash
```

The direct installer can be [inspected before it is run](https://raw.githubusercontent.com/ariakalantari/agenticmode/main/install.sh). Homebrew asks for an administrator password on the first awake-mode run; the direct installer asks once during installation. This installs a minimal safety watchdog in `/Library/PrivilegedHelperTools`.

Every command is also available through the shorter `am` alias. For example, `am current` is equivalent to `agenticmode current`.

Upgrade through the same channel that installed the CLI:

```bash
agenticmode update
# or: am update
```

Homebrew installs delegate to `brew update` and `brew upgrade`. Installer-managed direct installs download the latest stable release, verify its published SHA-256 checksum and shell syntax, and replace the managed files with rollback protection. Pinned ref installs and source checkouts are left untouched with an actionable error.

See [Installation and upgrades](https://github.com/ariakalantari/agenticmode/wiki/Installation-and-Upgrades) for pinned installs, checkout installs, custom paths, upgrades, and uninstall instructions.

### 2. Start a safe tracked run

Wrapping a new command gives the clearest lifetime boundary:

```bash
agenticmode run -- codex exec "finish the test suite"
```

Or snapshot work that is already active and add unattended safety limits:

```bash
agenticmode current --timeout 8h --min-battery 20
```

`current` waits only for the runs found at startup. Work started later does not extend the awake lease.

### 3. Check or stop it

From another terminal:

```bash
agenticmode status --verbose
agenticmode off
```

Normal completion restores the sleep setting that existed before agenticmode started. `agenticmode off` is the explicit recovery command: it stops any active controller or orphaned watchdog and sets `SleepDisabled` to `0`.

## Pick the right mode

| What you need | Command | What is tracked |
| --- | --- | --- |
| Launch one agent or script | `agenticmode run -- command` | Exact top-level child PID |
| Finish work already running | `agenticmode current` | A snapshot of detected runs |
| Wait for known processes | `agenticmode wait PID...` | Exact PIDs and process start times |
| Stay awake until manually stopped | `agenticmode` | Controller lifetime |
| Preview `current` safely | `agenticmode detect` | Read-only detection; no power change |

For interactive agents, prefer `run --` when possible. Long-lived TUI processes can remain open between prompts, so process lifetime is not always the same as work lifetime. See [Tracking modes](https://github.com/ariakalantari/agenticmode/wiki/Tracking-Modes) for detection details, supported command shapes, and tradeoffs.

## Terminal status

Long-running commands print compact, aligned status lines. The text label always carries the meaning; color is an optional secondary cue that is enabled only in a terminal. `NO_COLOR` and `TERM=dumb` disable color, while `FORCE_COLOR=1` enables it explicitly.

| Label | Meaning |
| --- | --- |
| `WORKING` | The run or operation is still active |
| `DONE` | Agenticmode observed explicit successful completion |
| `ABORTED` | Codex explicitly reported an aborted turn |
| `ENDED` | A process or activity is no longer active, but its result is unknown |
| `OK` | A health check passed or tracking completed safely |
| `FAILED` | A wrapped command returned a nonzero status |

`current` shows session titles by default and prints only state changes as work finishes. Exact turn IDs, PIDs, and lifecycle details remain available through `agenticmode status --verbose`.

For automation, `agenticmode status --machine` emits uncolored `key=value` lines. An active controller reports `sleep_disabled`, `controller`, `mode`, `controller_pid`, `started`, `restore_baseline`, `watchdog`, and, when available, `watchdog_pid`, `deadline_epoch`, and `tracked_runs_remaining`. An inactive controller reports only `sleep_disabled` and `controller`. The command exits `0` for a healthy active controller or a safely inactive system, and `2` for an inconsistent or unhealthy state. `--machine` and `--verbose` are mutually exclusive.

## Common commands

```bash
# Keep awake until Ctrl+C or `agenticmode off`
agenticmode --timeout 8h --min-battery 20

# Show what `current` can see without changing power settings
agenticmode detect

# Diagnose installation, permissions, and runtime state
agenticmode doctor

# Show the effective configuration
agenticmode config

# Restore normal lid-close sleep
agenticmode off
```

Timeouts accept `s`, `m`, `h`, or `d`, up to 365 days. A timeout or battery cutoff ends only the awake lease; it never kills a tracked agent or wrapped command.

## Supported agent tracking

- **Codex:** `current` reads local turn lifecycle records and excludes the invoking task and its known ancestors.
- **OpenCode:** an [opt-in plugin](https://github.com/ariakalantari/agenticmode/wiki/OpenCode-Integration) publishes exact `busy`, `retry`, and `idle` activity generations.
- **Claude Code, Gemini CLI, Aider, and OpenCode:** conservative process detection recognizes supported one-shot command forms.
- **Anything else:** use `run --`, `wait PID`, or an explicit custom process name.

Agenticmode reads lifecycle and process state but never signals, cancels, or modifies a tracked agent run. See [Tracking modes](https://github.com/ariakalantari/agenticmode/wiki/Tracking-Modes) for the exact guarantees and limitations of each detector.

## Safety model

- The main controller runs as your user; only the small watchdog is privileged.
- The watchdog owns, verifies, and periodically reasserts the `pmset` override.
- Normal exits, signals, timeouts, battery cutoffs, and tracked-run completion restore the previous setting.
- PID start times, owner-only state, symlink checks, and kernel-backed locks guard against stale or unsafe state.
- `agenticmode off` remains available from any terminal.
- Agenticmode never kills tracked work.

Read [Safety and reliability](https://github.com/ariakalantari/agenticmode/wiki/Safety-and-Reliability) before using closed-lid mode unattended.

## Documentation

- [Getting started](https://github.com/ariakalantari/agenticmode/wiki/Getting-Started)
- [Installation and upgrades](https://github.com/ariakalantari/agenticmode/wiki/Installation-and-Upgrades)
- [Tracking modes](https://github.com/ariakalantari/agenticmode/wiki/Tracking-Modes)
- [OpenCode integration](https://github.com/ariakalantari/agenticmode/wiki/OpenCode-Integration)
- [Configuration](https://github.com/ariakalantari/agenticmode/wiki/Configuration)
- [Safety and reliability](https://github.com/ariakalantari/agenticmode/wiki/Safety-and-Reliability)
- [Troubleshooting](https://github.com/ariakalantari/agenticmode/wiki/Troubleshooting)

Command reference is always available locally:

```bash
agenticmode --help
```

## Contributing and support

Found a bug or have an idea? [Open an issue](https://github.com/ariakalantari/agenticmode/issues). Pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

Run the full test suite without touching real power settings:

```bash
./tests/test_agenticmode.sh
```

## License

[MIT](LICENSE)
