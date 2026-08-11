# agenticmode

[![CI](https://github.com/ariakalantari/agenticmode/actions/workflows/ci.yml/badge.svg)](https://github.com/ariakalantari/agenticmode/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Keep a Mac laptop awake with its lid closed until your agent work is done.

`agenticmode` is a dependency-free macOS command-line tool, also available through the shorter `am` command. It can follow exact Codex turns, published OpenCode activity, supported one-shot agent processes, a command you launch, or PIDs you already know. A small root-owned watchdog restores the previous sleep setting when the controller exits—even if that controller is killed.

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

The direct installer can be [inspected before it is run](https://raw.githubusercontent.com/ariakalantari/agenticmode/main/install.sh). Both methods provide `agenticmode` and `am`. The direct installer asks for an administrator password during installation to place the minimal root-owned safety watchdog in `/Library/PrivilegedHelperTools`; Homebrew does this on the first awake-mode run.

Every command works with either name. For example, `am current` is equivalent to `agenticmode current`.

See [Installation and upgrades](https://github.com/ariakalantari/agenticmode/wiki/Installation-and-Upgrades) for pinned installs, checkout installs, custom paths, upgrades, and uninstall instructions.

### 2. Update

Update through the same channel that installed the CLI:

```bash
am update
```

| Installation | What `am update` does |
| --- | --- |
| Homebrew | Refreshes Homebrew, then upgrades only the agenticmode formula |
| Managed direct install | Downloads the latest stable release, verifies its SHA-256 checksum, archive paths, and shell syntax, then installs with rollback protection |
| Pinned ref | Leaves the pinned version unchanged and explains how to return to stable releases |
| Source checkout | Leaves the checkout unchanged and directs you to update it with Git |

Updates are refused while an awake controller, watchdog, or sleep override is active. Run `am off` first. Direct installs created before v1.3.0 need the direct installer run once more to add `am update` and migrate their installation metadata.

### 3. Start a safe tracked run

Wrapping a new command gives the clearest lifetime boundary:

```bash
am run -- codex exec "finish the test suite"
```

Or snapshot work that is already active and add unattended safety limits:

```bash
am current --timeout 8h --min-battery 20
```

`current` waits only for the runs found at startup. Work started later does not extend the awake lease.

### 4. Check or stop it

From another terminal:

```bash
am status --verbose
am off
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

Long-running commands open a full-screen terminal view when stdout is an interactive terminal. It uses the available width and height for a centered status panel, elapsed time, tracked-run progress, and an animated laptop. The layout redraws itself after a terminal resize and progressively simplifies in small windows. Startup and completion messages remain in the normal scrollback after the full-screen view closes.

Use `--no-ui` for compact line output, or set `AGENTICMODE_UI=plain` to make that the default. Pipes, redirected output, `TERM=dumb`, and `agenticmode run -- command` always use line output so logs and wrapped-command output remain intact. Interactive line output is capped to a readable measure and wraps with a hanging indent instead of relying on accidental terminal wrapping.

The text label always carries the meaning; color is an optional secondary cue that is enabled only in a terminal. `NO_COLOR` disables color, while `FORCE_COLOR=1` enables it explicitly.

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
# Keep awake until Ctrl+C or `am off`
am --timeout 8h --min-battery 20

# Show what `current` can see without changing power settings
am detect

# Diagnose installation, permissions, and runtime state
am doctor

# Show the effective configuration
am config

# Update through the owning installation channel
am update

# Restore normal lid-close sleep
am off
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
am --help
# or: agenticmode --help
```

## Contributing and support

Found a bug or have an idea? [Open an issue](https://github.com/ariakalantari/agenticmode/issues). Pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

Run the full test suite without touching real power settings:

```bash
./tests/test_agenticmode.sh
```

## License

[MIT](LICENSE)
