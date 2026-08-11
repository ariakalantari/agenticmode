# Contributing

Forks, bug reports, feature ideas, and pull requests are welcome.

## Pull requests

1. Fork the repository and create a focused branch.
2. Keep the implementation compatible with the Bash 3.2 shipped by macOS.
3. Run `./tests/test_agenticmode.sh` on macOS.
4. Explain power-management or detection behavior changes in the pull request.
5. Update the README when user-facing behavior changes.

Pull requests require review from the repository owner. Only `@ariakalantari` can merge or otherwise update `main`. Contributors can freely open pull requests from forks or branches, but approval does not grant merge access.

## Safety expectations

Changes must preserve the current sleep setting during normal cleanup, must never kill or modify agent runs, and must keep `agenticmode off` as the explicit path back to normal sleep. Keep privileged logic inside the small watchdog helper and preserve its root ownership checks. Tests must use the included fake `pmset`, `sudo`, and watchdog paths, never the Mac's real power settings.

## Scope

The project intentionally uses macOS and shell built-ins. Avoid third-party runtime dependencies. New agent detectors should default to conservative behavior and document false-positive and false-negative tradeoffs.
