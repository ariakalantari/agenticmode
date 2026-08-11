# agenticmode

`agenticmode` is a dependency-free macOS command line tool that keeps a Mac laptop running with its lid closed while development agents work. It uses the macOS power setting that covers lid-close sleep, adds a privileged safety watchdog, and never directly signals or modifies a tracked agent run.

## Install with Homebrew

Homebrew users can install and receive updates without keeping a checkout:

```bash
brew tap ariakalantari/agenticmode https://github.com/ariakalantari/agenticmode
brew install ariakalantari/agenticmode/agenticmode
```

The explicit repository URL is needed because this project doubles as its own tap instead of using a separate `homebrew-agenticmode` repository. Upgrade normally with `brew update && brew upgrade agenticmode`.

Homebrew installs the command without elevated privileges. The first awake-mode run installs the root-owned safety watchdog and asks for an administrator password once.

## Install directly

No package manager is required:

```bash
curl -fsSL https://raw.githubusercontent.com/ariakalantari/agenticmode/main/install.sh | /bin/bash
```

This keeps a small managed copy under `~/.local/share/agenticmode` and adds one `agenticmode` symlink to a writable directory already on `PATH`. To audit before running, download `install.sh`, inspect it, and then run it with `/bin/bash`.

Like the checkout installer, it installs the root-owned safety watchdog and asks for an administrator password once.

The direct installer follows `main` by default. Pin both the script and downloaded files to a release tag or commit when reproducibility matters:

```bash
ref=YOUR_RELEASE_TAG_OR_COMMIT
curl -fsSL "https://raw.githubusercontent.com/ariakalantari/agenticmode/$ref/install.sh" |
  AGENTICMODE_INSTALL_REF="$ref" /bin/bash
```

Use a specific command prefix or managed-source directory if needed:

```bash
curl -fsSL https://raw.githubusercontent.com/ariakalantari/agenticmode/main/install.sh |
  PREFIX="$HOME/.local" AGENTICMODE_INSTALL_DIR="$HOME/Library/Application Support/agenticmode" /bin/bash
```

## Install from a checkout

```bash
git clone https://github.com/ariakalantari/agenticmode.git ~/Documents/agenticmode
~/Documents/agenticmode/install.sh
```

The checkout installer adds one symlink named `agenticmode` to a writable directory already on `PATH`. It also installs a minimal root-owned safety watchdog in `/Library/PrivilegedHelperTools`, so macOS asks for an administrator password once during installation. An older symlink-only installation will install this helper on the next active run. On an Apple silicon Mac with Homebrew, the command symlink is normally `/opt/homebrew/bin`.

Use a specific prefix if needed:

```bash
PREFIX="$HOME/.local" ~/Documents/agenticmode/install.sh
```

The installer is idempotent and refuses to replace another file or unrelated symlink. `./install.sh --force` can replace an unrelated symlink when that is intentional.

## Quick start

Keep the Mac awake until you stop the foreground controller:

```bash
agenticmode
```

Press Ctrl+C, or use `agenticmode off` in another terminal. The Mac stays awake even after agent runs finish.

Snapshot the runs active right now and restore the previous setting when those exact runs finish:

```bash
agenticmode current
```

Wrap one command for exact lifetime tracking:

```bash
agenticmode run -- codex exec "finish the test suite"
```

Wait for one or more existing process IDs:

```bash
agenticmode wait 1234 5678
```

Inspect behavior without changing power settings:

```bash
agenticmode detect
agenticmode status --verbose
agenticmode doctor
```

Restore normal lid-close sleep from any terminal:

```bash
agenticmode off
```

`off` intentionally sets `SleepDisabled` to `0`. Normal automatic cleanup restores the setting that existed before agenticmode started.

Only one awake controller can own the Mac at a time. Starting another mode while one is active fails without changing state or running a wrapped command. Use `status`, wait for the current mode, or run `off` first.

## Useful safety limits

Stop after a maximum duration:

```bash
agenticmode --timeout 8h
agenticmode current --timeout 90m
```

Stop when the battery reaches a threshold while running on battery:

```bash
agenticmode --min-battery 25
```

Combine both limits:

```bash
agenticmode current --timeout 12h --min-battery 20
```

Durations accept `s`, `m`, `h`, or `d`, up to 365 days. A value of `0` disables the limit.

A timeout or battery cutoff ends only the awake lease. It never kills a tracked or wrapped command. If work is still running, agenticmode returns exit status `75` and prints the child PID when one is known. This prevents `agenticmode run -- tests && deploy` from starting deployment after an incomplete test run.

## Choosing the right tracking mode

| Need | Command | Tracking confidence |
| --- | --- | --- |
| Stay awake until manually stopped | `agenticmode` | Exact controller lifetime |
| Finish Codex turns active at startup | `agenticmode current` | Exact observed turn lifecycle |
| Finish OpenCode work active at startup | `agenticmode current` with the opt-in plugin | Exact published status and activity generation |
| Finish supported one-shot agent commands | `agenticmode current` | Exact detected PID lifetime |
| Run a new agent command | `agenticmode run -- command` | Exact top-level child PID lifetime unless manually stopped or cut off |
| Wait for a known existing command | `agenticmode wait PID` | Exact supplied PID and process start time |
| Include interactive agent sessions | `agenticmode current --process-policy session` | Conservative process lifetime |

For interactive agents, `run --` is the most reliable option. A long-lived interactive CLI remains open between prompts, so its process lifetime is not the same as a single agent run.

`run --` and `wait PID` follow only the selected top-level PID, not its complete descendant process tree. If that process daemonizes or exits after launching background work, the awake lease can end while descendants continue. Wrap a command that remains alive for the whole job, or wait on the long-lived worker PID instead. Also note that terminal-generated Ctrl+C and Ctrl+Z can reach a wrapped foreground command through the terminal process group even though agenticmode never sends those signals to tracked PIDs itself.

## How `current` detects runs

macOS does not expose a universal concept of an agent run. `agenticmode current` therefore takes a read-only snapshot from Codex lifecycle records, activities published by installed harness integrations, and conservative process detection.

### Codex turns

Codex desktop, CLI, and subagent turns are identified from lifecycle records under `$CODEX_HOME/sessions`, or `~/.codex/sessions` by default. Lifecycle events are replayed globally by turn ID, which handles multiple active turns in one file and deduplicates parent history copied into subagent files.

When agenticmode is launched from inside a Codex task, that task and its known ancestors are excluded. This prevents `current` from waiting for the task that invoked it. The ancestor lookup uses Codex's local state database when it is available.

The snapshot records exact turn IDs. Runs started later do not extend the wait. A tracked turn ends on `task_complete` or `turn_aborted`. Global lifecycle replay happens once while building the snapshot. Ongoing polling follows the selected canonical rollout and reads only bytes appended after the snapshot, which avoids rescanning large histories. Agenticmode only reads these files and never contacts, cancels, or edits Codex.

The JSONL lifecycle format is an internal Codex detail, not a promised stable API. `agenticmode detect` shows what the current version can see. If a Codex update changes the format, use `agenticmode run -- ...` or `agenticmode wait PID` until the detector is updated.

### OpenCode activities (opt-in)

OpenCode exposes `busy`, `retry`, and `idle` session states to plugins. The included adapter publishes those events to agenticmode, allowing `current` to track an interactive OpenCode activity instead of the complete lifetime of its long-running TUI or server process.

Install the adapter explicitly after installing agenticmode:

```bash
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins"
cp ~/Documents/agenticmode/integrations/opencode/agenticmode.js \
  "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/agenticmode.js"
```

Restart OpenCode, start a prompt, and run `agenticmode detect` from another terminal to verify the activity. The `agenticmode` command must be on the `PATH` inherited by OpenCode. Set `AGENTICMODE_OPENCODE_DEBUG=1` before starting OpenCode to send adapter failures to its diagnostic output; adapter failures never block a session.

The adapter treats `busy` and `retry` as active, and `idle` or deletion as finished. Each activation gets a unique generation, so later work in the same OpenCode session cannot extend a snapshot of earlier work. Records also include the OpenCode process ID and exact start time, preventing a crash, stale record, or reused PID from holding the awake lease. When a command runs inside OpenCode, the plugin identifies its exact source session so `current` excludes only its caller rather than every session sharing the OpenCode server process.

This is exact relative to the lifecycle state published by OpenCode, not an independent guarantee that the harness itself never reports a stale state. The adapter uses the documented [OpenCode plugin event surface](https://opencode.ai/docs/plugins/).

To remove the integration, quit OpenCode and delete the copied file:

```bash
rm "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/agenticmode.js"
```

The main installer deliberately does not edit OpenCode configuration.

### Other agent CLIs

The default `oneshot` process policy includes only command shapes that normally represent one run. It recognizes native executables and conservative shell, Node.js, Python module, npx, bunx, and uvx wrapper layouts:

- Claude Code with `-p` or `--print`
- Gemini CLI with `-p` or `--prompt`
- Aider with `-m` or `--message`
- OpenCode with `run`

Codex processes are not added as generic process targets because Codex desktop and interactive CLI processes can remain alive after a turn finishes.

Interactive Claude Code turns are not currently treated as exact lifecycle activities. Claude's documented `Stop` hook does not fire on user interruption, hooks can block prompt submission or prevent a stop, and background work can outlive the main response. Those gaps can either allow sleep during continued work or leave sleep disabled while an interactive process waits at its prompt. Claude Code `-p`/`--print` remains supported by one-shot process detection; use `agenticmode run -- claude ...` or session process policy when full interactive-process lifetime is the safer boundary. See the official [Claude Code hooks lifecycle](https://code.claude.com/docs/en/hooks#hook-lifecycle).

Use `--process-policy session` to wait for the full lifetime of recognized interactive sessions. Use `--process NAME` for another executable name, or put persistent custom names in `custom_process_names`. Explicit custom process names are treated as session processes, so they may remain active while waiting for input.

Process targets store both PID and process start time, are limited to the current macOS user, and are monitored without sending signals.

## Configuration

The default config path is:

```text
~/.config/agenticmode/config
```

Start from [`config.example`](config.example):

```bash
mkdir -p ~/.config/agenticmode
cp ~/Documents/agenticmode/config.example ~/.config/agenticmode/config
chmod 600 ~/.config/agenticmode/config
```

Supported keys:

| Key | Default | Purpose |
| --- | --- | --- |
| `poll_seconds` | `5` | Check interval from 1 to 300 seconds |
| `timeout` | `0` | Maximum duration, with `0` meaning unlimited |
| `min_battery` | `0` | Stop percentage on battery, with `0` disabled |
| `include_codex` | `1` | Enable Codex lifecycle detection |
| `include_processes` | `1` | Enable known process detection |
| `include_activities` | `1` | Enable activities published by installed harness integrations |
| `process_policy` | `oneshot` | Use `oneshot` or `session` matching |
| `process_names` | built-in list | Comma-separated executable names |
| `custom_process_names` | empty | Extra executable names tracked for their full session lifetime |
| `codex_stale_seconds` | `0` | Ignore active Codex files older than this, with `0` disabled |
| `codex_home` | automatic | Override the Codex data directory |

Precedence is command line flags, `AGENTICMODE_*` environment variables, the config file, then defaults. Config files use strict `key=value` lines, are never executed, reject unknown keys, reject symlinks, and must not be group- or world-writable.

Keep `codex_stale_seconds=0` unless you explicitly prefer an age cutoff. A nonzero value can exclude a legitimate quiet, long-running Codex turn and allow sleep before it finishes.

Show the effective configuration:

```bash
agenticmode config
agenticmode config --config /path/to/config
```

## Reliability and cleanup

Starting a mode authenticates once with `sudo`, then launches the minimal root-owned watchdog installed by `install.sh`. The main command remains unprivileged. The watchdog owns the `pmset` change, verifies that it took effect, reasserts it at least every two seconds, and retries and verifies restoration when the controller exits.

This avoids relying on a cached `sudo` credential hours later. It also restores the prior setting if the unprivileged controller is killed with `SIGKILL`. Controller state is stored in `~/Library/Caches/agenticmode` with owner-only permissions and PID start-time checks to prevent stale PID reuse.

Normal cleanup covers Ctrl+C, SIGTERM, SIGHUP, timeouts, battery cutoff, tracked-run completion, and ordinary command completion. `agenticmode off` asks an active controller to clean up, waits for any orphaned watchdog, then explicitly restores normal sleep. Start and stop state changes use a kernel-backed macOS lock, and each watchdog has a unique persistent stop lease. A concurrent `off`, delayed helper, or immediate restart therefore cannot overtake a controller that is still starting.

Ctrl+Z is not a pause mechanism for agenticmode. It ends the awake lease and restores the prior setting. A command wrapped by `run --` may remain stopped by the terminal signal.

A direct `SIGKILL` of the privileged watchdog, kernel failure, or abrupt power loss cannot run cleanup. After any abnormal event, check:

```bash
agenticmode status
agenticmode off
```

The macOS power setting is global, while controller state is per user. Concurrent agenticmode controllers from different logged-in user accounts are not supported.

## macOS behavior and safety

The tool applies:

```bash
sudo pmset -a disablesleep 1
```

Apple documents this setting as disabling all sleep functions. An ordinary idle-sleep assertion, including `caffeinate -i`, can still allow lid-close sleep, so it does not solve this specific case.

This setting disables system sleep, not only lid-close sleep. The display can still turn off.

- Keep the Mac on a hard, ventilated surface.
- Never put it in a bag while agenticmode is active.
- Prefer external power for long closed-lid work.
- Use `--timeout` and `--min-battery` for unattended runs.
- macOS may still force shutdown or sleep for thermal or battery protection.

Apple's supported closed-display setup uses external power plus an external display, keyboard, and mouse. Running headless with `disablesleep` is a command-line power-management override, not the standard clamshell setup.

Sources:

- [Apple Support: prevent sleep with pmset](https://support.apple.com/ja-jp/101114)
- [Apple Developer: idle-sleep assertions still allow lid-close sleep](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)
- [Apple Support: closed-display requirements](https://support.apple.com/en-nz/102501)
- The local `pmset(1)` and `caffeinate(8)` manual pages included with macOS

`disablesleep` is accepted by current macOS and documented in the Apple Support article, but it is absent from the settings list in the current local `pmset(1)` manual. Agenticmode verifies the reported `SleepDisabled` value after every change.

## Troubleshooting

If `current` finds nothing:

```bash
agenticmode detect
agenticmode doctor
```

If it waits longer than expected:

```bash
agenticmode status --verbose
agenticmode off
```

Common causes are a long-lived interactive session selected with `process_policy=session`, an active Codex turn without a terminal lifecycle event, a missing OpenCode adapter or inherited `PATH`, or an unsupported wrapper command. Prefer `agenticmode run -- command` for unusual tools and wrappers.

## Development and contributions

Run the full suite without touching real power settings:

```bash
./tests/test_agenticmode.sh
```

The suite replaces `pmset` and `sudo` with local fakes. It covers signal cleanup, `SIGKILL` recovery, immediate orphan shutdown and restart, delayed watchdog registration, atomic state locking, restoration retries and failures, baseline preservation, watchdog reassertion, long-poll interruption, controller conflicts, Codex deduplication, appended-only polling, exact OpenCode activity generations, concurrent publication, stale and malicious activity records, caller exclusion with shared harness processes, native and wrapped process detection, exact command and PID modes, cutoff exit statuses, battery query failures, config safety, installer ownership checks, and idempotent shutdown.

Forks and pull requests are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md). Changes to `main` require the repository owner's review, and only `@ariakalantari` can merge.

## Uninstall

For a direct install:

```bash
~/.local/share/agenticmode/uninstall.sh
```

Use `$AGENTICMODE_INSTALL_DIR/uninstall.sh` if the managed source directory was customized.

For Homebrew, remove the privileged helper before uninstalling the formula:

```bash
agenticmode off
sudo rm -f /Library/PrivilegedHelperTools/com.ariakalantari.agenticmode.watchdog
brew uninstall ariakalantari/agenticmode/agenticmode
brew untap ariakalantari/agenticmode
```

For a checkout install:

```bash
cd ~/Documents/agenticmode
./uninstall.sh
```

The uninstaller turns off an active override before removing this checkout's symlink. For a custom install prefix, run `PREFIX=/path ./uninstall.sh`.

## License

MIT
