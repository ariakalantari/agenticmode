# agenticmode

`agenticmode` is a small macOS command line tool for keeping a Mac laptop running while its lid is closed. It uses macOS power management directly and does not require a third-party app.

## Install

Clone the repository into Documents and run the installer:

```bash
git clone https://github.com/ariakalantari/agenticmode.git ~/Documents/agenticmode
cd ~/Documents/agenticmode
./install.sh
```

The installer creates a symlink named `agenticmode` in a writable directory already on `PATH` when possible. On Apple silicon Macs with Homebrew, this is normally `/opt/homebrew/bin`.

To install somewhere specific:

```bash
PREFIX="$HOME/.local" ./install.sh
```

## Use

Keep the Mac awake indefinitely:

```bash
agenticmode
```

The command stays in the foreground. Closing the lid does not stop it. Press Ctrl+C when you are done, or run `agenticmode off` from another terminal. Normal sleep is restored before the foreground process exits.

Keep the Mac awake only for agent runs that are active when the command starts:

```bash
agenticmode current
```

This takes a snapshot. Runs started later are not included. When every snapshotted run has completed or been interrupted, normal sleep is restored automatically.

Turn the mode off from another terminal:

```bash
agenticmode off
```

Check the current state:

```bash
agenticmode status
```

All commands are idempotent. Starting a second controller reports the existing controller instead of changing ownership. Running `off` when normal sleep is already enabled is safe.

## How current-run detection works

There is no universal macOS concept of an "agent run," and desktop Codex tasks do not each have their own operating-system process. The Codex desktop app uses one long-lived app-server process for many tasks, so waiting for every process named `codex` would never finish.

`agenticmode current` uses two read-only strategies:

1. Codex desktop, CLI, and subagent turns are detected from JSONL lifecycle events under `$CODEX_HOME/sessions`, or `~/.codex/sessions` when `CODEX_HOME` is unset. A turn is active when its latest lifecycle event is `task_started`. The tool snapshots the exact turn ID, then waits for `task_complete` or `turn_aborted` for that same ID. It does not edit the logs, connect to the app-server, cancel work, or start new work.
2. Standalone agent CLIs are detected by process name and command line. The built-in list covers Codex, Claude Code, Gemini CLI, Aider, and OpenCode. The tool records both PID and process start time to protect against PID reuse. It only waits and never signals these processes.

The Codex lifecycle strategy is based on the same thread and turn model documented by the [Codex app-server reference](https://github.com/openai/codex/tree/main/codex-rs/app-server). It is stronger than process-name guessing for the Codex desktop app, but the on-disk JSONL format is not a promised stable public interface. If a future Codex release changes those lifecycle records, Codex desktop detection may miss a run. Process matching for other agents is intentionally conservative and may miss a wrapper with an unusual executable name.

If a tracked Codex process crashes without writing a completion or abort event, `current` may continue waiting. Use Ctrl+C or `agenticmode off` to restore normal sleep immediately.

## Why this uses pmset instead of caffeinate

The tool runs:

```bash
sudo pmset -a disablesleep 1
```

and restores normal behavior with:

```bash
sudo pmset -a disablesleep 0
```

Apple documents `disablesleep 1` as disabling all sleep functions. Apple's power assertion documentation also says an idle-sleep assertion can still allow sleep for lid close, low battery, the Apple menu, and other non-idle reasons. That is why `caffeinate -i` alone is not sufficient for this use case.

Sources:

- [Apple Support: prevent sleep with pmset](https://support.apple.com/ja-jp/101114)
- [Apple Developer: idle-sleep assertions still allow lid-close sleep](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)
- [Apple Support: Apple's supported closed-display setup requires power and external input devices](https://support.apple.com/en-nz/102501)
- The local `pmset(1)` and `caffeinate(8)` manual pages installed with macOS

`disablesleep` is accepted by current macOS and is documented in the Apple Support article above, but it is not listed among the settings in the current local `pmset(1)` manual. This project treats that mismatch as an implementation caveat and verifies the resulting `SleepDisabled` value after every change.

## Safety

This setting disables all system sleep, not only lid-close sleep. The display can still turn off.

- Keep the Mac on a hard, ventilated surface.
- Do not put it in a bag while the mode is active.
- Prefer power from a charger or display. Running closed on battery can drain the battery and create heat.
- macOS can still force sleep or shutdown for low battery, thermal protection, or other safety reasons.
- Always use `agenticmode off` if a controller was force-killed or the terminal crashed. SIGKILL and sudden power loss cannot run shell cleanup traps.

The command verifies `SleepDisabled` after enabling and disabling it. Ctrl+C, SIGTERM, SIGHUP, normal completion, and handled failures all run the same cleanup path.

## Development

Run the tests without changing the real Mac power state:

```bash
./tests/test_agenticmode.sh
```

The tests replace `pmset` and `sudo` with local fakes and use temporary Codex session fixtures.

## Uninstall

First restore normal sleep, then remove the symlink:

```bash
agenticmode off
cd ~/Documents/agenticmode
./uninstall.sh
```

## License

MIT
