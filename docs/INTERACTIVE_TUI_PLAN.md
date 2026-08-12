# Interactive TUI plan

## Outcome

Agenticmode should feel like one coherent terminal application rather than a
stream of shell output:

- After an opt-in release proves the implementation, exactly zero-argument
  `am` opens a keyboard-driven launcher when input, output, and the foreground
  controlling TTY are all usable.
- Existing explicit commands and every non-interactive invocation retain their
  current behavior and machine-readable output.
- The live dashboard always recomputes its layout from the current terminal
  width and height. Resizing changes the composition, not merely the amount of
  text clipped from a fixed design.
- The terminal application owns input while it is visible, so arrow keys never
  echo escape bytes or overwrite rendered content.
- The Bash controller and privileged watchdog remain the authority for power
  state and restoration. The presentation layer must never be able to weaken
  those guarantees.

## Research basis

Claude Code's fullscreen renderer is the relevant interaction model: it uses
the alternate screen, keeps important controls at stable positions, renders
only visible content, supports keyboard and mouse menus, and provides a full
repaint escape hatch for terminal emulators that mishandle incremental cell
updates. Its narrow layouts shorten content instead of wrapping it across
unrelated rows.

Bubble Tea v2 provides the corresponding implementation primitives on macOS:
raw terminal input, structured key events, `WindowSizeMsg`, alternate-screen
ownership, synchronized output, cursor management, color downsampling, and a
declarative view. Bubbles supplies list, progress, viewport, and help models;
Lip Gloss supplies display-cell-aware measurement, truncation, placement, and
color blending. Claude Code's fullscreen renderer is itself a research preview,
so the target is the same principles and quality bar, not an identical-rendering
compatibility promise.

Primary references:

- <https://code.claude.com/docs/en/fullscreen>
- <https://code.claude.com/docs/en/interactive-mode>
- <https://github.com/charmbracelet/bubbletea/releases/latest>
- <https://github.com/charmbracelet/bubbles/releases/latest>
- <https://github.com/charmbracelet/lipgloss>
- <https://pubs.opengroup.org/onlinepubs/007904975/basedefs/xbd_chap11.html>

## Product model

Do not model every cutoff as a mutually exclusive mode. There are two separate
questions:

1. What work ends the awake lease?
2. What safety limits may end it earlier?

The launcher therefore edits a typed launch specification instead of building
a shell command string.

### Main screen

The initial focus is on `Keep awake until`, followed by a compact summary of
the current choices:

1. **Current agents finish** — snapshot all detected agent work, selected
   providers, or selected individual runs.
2. **I turn it off** — the current manual mode.
3. **Selected processes finish** — choose exact detected processes or enter a
   PID.
4. **A timer expires** — duration picker with common presets and a validated
   custom value.

The same screen exposes optional safety limits:

- **Battery floor** — off by default; common presets plus a 1% adjustable
  value. It is a cutoff, not a promise to drain to that level.
- **Maximum duration** — available even when agents or processes are the main
  completion condition.

The bottom action is a full sentence such as `Start: current 3 agents, stop at
25% battery, 8h maximum`. Enter opens a confirmation screen when the selection
would create an indefinite lease or when no current agents were detected.

Treat a timer as manual mode with a required maximum duration; do not show a
second, duplicate maximum-duration field in that flow. The inactive home also
links to read-only detection, doctor, config, update, and help. When a controller
is already active, open an active home containing the dashboard, verbose status,
and stop action rather than offering a second start. `run -- command` remains an
explicit CLI-only expert flow because accepting an arbitrary shell command in a
menu would create quoting and trust problems.

### Current-agent picker

Run detection before changing power state. Show:

- `All detected runs (N)` as the safe default.
- Provider groups such as Codex lifecycle sessions and supported CLI
  processes.
- Individual runs with the same session title used by Codex, status source,
  and a one-line ellipsis.

Space toggles an item, Enter confirms, Escape goes back, `/` filters, and
Up/Down or `j`/`k` moves. Selection is by the immutable identity already used
by the backend, never by title or list index.

This requires a new backend target-selection API; the current controller cannot
start `current` for an arbitrary subset of Codex turns or activities. Detection
creates a private mapping from opaque, one-use handles to immutable target
records. The helper may return only handles it was given. Bash revalidates every
selection immediately before starting the watchdog. If none remain, do not call
`pmset`; return to the picker and explain that the work finished while the menu
was open. Manually entered PIDs follow a separate numeric validation and
PID-start-time capture path.

### Battery picker

Show the current charge as a wide bar and place a visible cutoff marker at the
chosen threshold. Left/Right changes by 1%, Shift+Left/Right by 5%, digits allow
direct entry, and common presets remain one keystroke away. When on AC power,
say that the floor activates after switching to battery. Unknown battery state
is an explicit error, matching the backend's current fail-closed behavior.

### Live dashboard

After launch, the dashboard contains:

- A compact AGENTIC/MODE brand mark, current mode, elapsed time, and active
  cutoff summary.
- A session viewport whose height grows and shrinks with the terminal.
- One row per run: animated working marker, state label, and single-line title.
- Battery bar and cutoff marker when battery protection is enabled.
- A stable footer with `Ctrl+C stop  ? help` and any context-specific keys.

Completed rows settle into a static success state. The active marker may pulse
at 4-6 frames per second. The battery fill may carry a low-contrast travelling
highlight, but the numeric percentage and cutoff marker always communicate the
real state. Motion is decoration, never state.

## Rendering architecture

### Safety boundary

Add a private `agenticmode-ui` Go helper built with Bubble Tea v2, Bubbles, and
Lip Gloss. It owns `/dev/tty`, key decoding, animation ticks, viewport state,
and drawing. It does not invoke `pmset`, write controller state, decide whether
a run is active, or restore sleep.

The Bash process remains the controller and watchdog supervisor. It atomically
publishes a bounded, owner-only, versioned view snapshot at its existing poll
cadence. Publication is best-effort and never waits for the helper. The helper
polls the latest snapshot and owns animation independently, so a hung renderer
cannot delay agent checks, the battery floor, timeout, or watchdog health. Cap
individual text fields, record count, and total snapshot bytes; excess targets
remain tracked by Bash and appear as an aggregate count.

Persist every presentation-relevant launch choice, including the battery floor
and cutoff summary, in that snapshot. The helper must not reverse-engineer the
controller's process arguments. Sanitize C0/C1 controls, ESC/CSI/OSC sequences,
tabs, newlines, and directional controls before publishing display text. Define
UTF-8/grapheme behavior explicitly and preserve ASCII `...` truncation, including
the existing defined clipping behavior below four cells.

For menu selection, the helper returns a typed, versioned launch specification;
Bash validates it again and maps opaque handles and scalar values to existing or
new option variables without `eval` or a shell command string.

For the live view, the controller owns, identifies, stops, and reaps the exact
helper child with bounded waits. The helper is a non-authoritative observer with
one capability: request that the controller stop. It can shorten a lease but
cannot extend one. Define one signal owner and the exact sequence `Ctrl+C key ->
stop request -> wake controller -> watchdog restoration`.

Bash captures `stty -g` before helper launch and retains an emergency recovery
path for helper panic, `SIGKILL`, wrong-version output, or malformed cleanup. On
helper failure, Bash restores termios, cursor visibility, styles, synchronized
output, bracketed-paste state, and the alternate screen before continuing in
plain mode. The helper detects parent death and performs its own best-effort
restore. Initially disable mouse, focus reporting, bracketed paste changes, and
progressive keyboard enhancements to minimize emergency-cleanup surface.

Fullscreen starts only when stdin and stdout are TTYs, `/dev/tty` is usable, and
the process group owns the foreground terminal. Background/detached invocations
must take the plain path rather than risk `SIGTTIN`. If the controller exits,
existing traps and the watchdog still restore the prior power setting. A UI
failure can reduce polish but cannot delay or extend the selected lease.

### Layout contract

Every render starts from `(width, height, capabilities, model)` and returns a
complete frame. No component caches absolute coordinates across a resize.

Choose the first matching semantic breakpoint, not one capped panel:

- **Tiny** (`<40` columns or `<10` rows): text logo, one selected row, terse
  footer, no decorative animation.
- **Compact** (otherwise, `<80` columns or `<20` rows): stacked sections, compact
  wordmark, short labels, scrollable list.
- **Standard** (otherwise, `<120` columns): full wordmark, summary, battery bar, and
  session viewport.
- **Wide** (all remaining sizes): two columns, with status/battery on the left and
  sessions on the right. Extra width becomes useful structure rather than a
  200-column line. Fall back to standard stacking if either column cannot meet
  its declared minimum content width.

The frame is exactly the current terminal size. All user content is truncated
by terminal display-cell width with `...`; it never wraps inside a list row.
The selected row remains visible after every resize. Height determines how
many sessions are visible, with a `N more` indicator or viewport scroll.

On every real `WindowSizeMsg`, update all component dimensions, invalidate the
old geometry, and render the complete new model. Use synchronized output when
the terminal reports support. Keep incremental rendering as the default. Before
promising full repaint, run a technical spike that names and tests how Bubble
Tea's cell cache is invalidated; the manual-redraw action must use that same
path. Provide an environment-controlled repaint fallback only after that path
is proven across the supported terminals.

### Terminal ownership and compatibility

The TUI must save the inherited terminal state, enter raw mode, consume its own
input, and restore the exact prior state on normal exit and signals. POSIX
explicitly distinguishes canonical input and echo; disabling only echo is not
enough because unread arrow sequences can be delivered to the shell after the
program exits. Do not add key handling to the current Bash renderer: its safety
loop does not read stdin, and raw mode changes Ctrl+C from a Bash signal into an
input byte.

Fallbacks are part of the design:

- Non-TTY input/output, `TERM=dumb`, `--no-ui`, and `AGENTICMODE_UI=plain` use
  the existing line interface.
- `NO_COLOR` removes color while preserving labels and shapes.
- `AGENTICMODE_REDUCED_MOTION=1` uses static markers and bars.
- `AGENTICMODE_UI_FULL_REPAINT=1` redraws every cell each frame.
- Unsupported mouse reporting never affects keyboard navigation.
- The first release enables keyboard only; mouse selection can follow after
  terminal and tmux coverage is proven.

## Animation direction

The `AGENTIC` over `MODE` wordmark is a persistent launcher header. A
three-to-five-cell brightness band may cross the occupied glyph cells during
the first few frames, then the wordmark settles in place while the menu stays
visible below it. Use true color when available, downsample to
ANSI-256/ANSI-16, and fall back to static ASCII under `NO_COLOR`, reduced
motion, or constrained geometry.

The menu is interactive on the first frame; no input is discarded to dismiss
the wordmark. Reduced motion means zero decorative tick messages, not merely
unchanging frames.

The live working marker should be calmer than the startup shimmer. Prefer a four-frame
filled-dot/blob deformation over spinner punctuation. The battery animation is
a narrow travelling highlight within the filled cells; the fill length changes
only when the measured percentage changes. Cap the renderer explicitly at 6
FPS, emit snapshot updates only for backend changes, and keep decorative ticks
inside Go. Measure idle CPU, memory, and terminal bytes per second at both
`80x24` and `200x60`. A hung or slow helper may not change any backend cutoff
beyond the controller's existing poll tolerance.

## Delivery stages

### Stage 0: visual-only Bash patch

- Replace the laptop with the responsive AGENTIC/MODE wordmark.
- Remove fixed maximum layout widths and make resize recompute the composition.
- Preserve exact terminal restoration through repeated Ctrl+C and resize.

This patch must not claim terminal input ownership or add a Bash key reader. It
can ship before the helper.

### Stage 1: terminal-owner foundation

- Add the Go module, reproducible packaging, compatibility handshake, minimal
  dashboard, controlling-TTY gate, raw input, resize, Ctrl+C routing, parent and
  child supervision, emergency restoration, and plain fallback.
- Prove the terminal-state and PTY recovery matrix before adding product menus.
- Add manual redraw/full repaint only after the renderer-invalidation spike.

### Stage 2: responsive live dashboard

- Atomically publish bounded observer snapshots while the Bash controller
  remains the supervisor; never synchronously stream through the helper.
- Add session viewport, cutoff summary, battery visualization, help overlay,
  resize reflow, reduced motion, and full repaint.
- Fall back to the Bash line UI if the helper cannot start or exits.

### Stage 3: experimental `am menu`

- Add the backend target-selection/revalidation API, typed launch
  specification, current-agent picker, manual/timer flow, exact-process picker,
  battery floor, and active/inactive homes.
- If the helper is missing or incompatible, `am menu` fails read-only and never
  falls through to an indefinite awake lease.
- Keep every existing invocation unchanged while the menu is exercised in
  Terminal.app, iTerm2, Ghostty, VS Code, and tmux for one release.

### Stage 4: make the launcher the interactive default

- First introduce `am start` as the explicit manual lease command.
- Only exactly zero-argument `am` may open the launcher. `am --timeout 8h`,
  `am --min-battery 25`, config-driven starts, non-interactive bare `am`, and all
  explicit commands preserve existing semantics.
- Add an opt-out config entry and document `am start` as the explicit manual
  lease command before changing the default.
- Add mouse selection only after keyboard behavior and terminal restoration
  have production coverage.

## Packaging

The helper adds Go source, pinned `go.mod`/`go.sum`, exact `charm.land/.../v2`
imports, dependency licences, a reproducible build, and a Bash/helper protocol
version handshake. Homebrew declares Go as a build dependency, builds from an
immutable source archive, and receives dependencies through vendored release
source or audited formula resources rather than a moving resolution.

Managed direct releases use version-specific `darwin-arm64` and `darwin-amd64`
artifacts or a version-specific manifest; never combine a `latest` shell archive
with a separately fetched `latest` helper. The installer maps `uname -m`,
verifies immutable checksums, and retains the prior install on any mismatch.
Do not claim signing unless a later plan names the signing mechanism, pinned
identity/public key, verification command, and release credentials.

The current installer, managed updater, archive allowlist, rollback loops,
uninstaller, Homebrew formula, doctor command, and release workflow all require
explicit companion-binary coverage. Source checkouts without a built helper
continue to work with the plain interface.

Do not make the end user install Go. Extend the release workflow and rollback
tests before enabling the helper by default.

## Verification gates

1. **Pure model tests** — deterministic state transitions for every key,
   selection, cancel path, invalid value, and combined cutoff.
2. **Golden layout tests** — at least `20x5`, `39x9`, `40x10`, `79x19`,
   `80x20`, `119x30`, `120x30`, `200x60`; assert exact height and that no line
   exceeds display-cell width.
3. **Resize tests** — continuously resize a PTY while moving selection and
   receiving session updates, using actual PTY geometry changes that generate
   `SIGWINCH`; assert no stale cells, wrapping, lost focus, or out-of-bounds
   cursor writes.
4. **Input tests** — arrows, `j/k`, Enter, Escape, digits, paste, key repeat,
   rapid Ctrl+C, and terminal-generated mouse bytes never appear as content. In
   a real PTY shell, exit and run a sentinel command to prove no queued bytes
   reached the shell.
5. **Terminal restoration tests** — compare `stty -g` before and after normal
   cancel, rapid Ctrl+C, helper panic, helper `SIGKILL`, controller TERM/HUP,
   resize, and `am off`.
6. **Safety tests** — helper hung/not-reading, malformed/truncated/oversized or
   wrong-version snapshots, closed TTY, `SIGTTIN`, controller crash, and
   watchdog recovery all restore the recorded baseline or retain recoverable
   state exactly as today. A selection that ends during confirmation performs
   no sleep override.
7. **Compatibility tests** — Terminal.app, iTerm2, Ghostty, VS Code's terminal,
   and tmux; color, `NO_COLOR`, reduced motion, plain mode, light/dark themes,
   stdin/stdout redirection combinations, `TERM=dumb`, background execution,
   detached TTYs, and both Apple Silicon and Intel release artifacts.
8. **Screen-model tests** — replay ANSI output through a terminal screen model
   and assert final cells, cursor bounds, stale-cell absence, and no wrapping;
   grep-only escape-log checks are insufficient.
9. **Install/update tests** — rollback after the shell was replaced but helper
   install or handshake failed; missing/incompatible helper behavior for
   `am menu`, zero-argument `am`, and explicit commands; Homebrew source build
   plus both architecture mappings.
10. **Performance budget** — idle dashboard at no more than 6 FPS, no render when
   model and animation frame are unchanged, bounded memory, and no full-screen
   clear except startup, resize, manual redraw, or explicit full-repaint mode.

## Acceptance criteria

- Arrow keys never print, overwrite the screen, or reach the shell after exit.
- Resizing immediately uses the new width and height, changes breakpoints when
  appropriate, and reveals/hides list rows without restarting the lease.
- No user-controlled value wraps inside a menu or session row.
- Every menu selection maps to the documented existing backend behavior.
- A helper that hangs, crashes, or receives malicious display data cannot delay
  agent, battery, timeout, or watchdog checks.
- Ctrl+C always leaves the terminal usable and initiates the existing verified
  sleep restoration path.
- The dashboard remains understandable with color and motion disabled.
- A presentation-layer failure cannot leave the machine awake longer than the
  backend's selected completion conditions.
