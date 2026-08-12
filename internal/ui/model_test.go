package ui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"github.com/ariakalantari/agenticmode/internal/protocol"
)

func launcherRequest() protocol.Request {
	return protocol.Request{
		Generation: 1,
		System:     protocol.SystemInactive,
		Power:      protocol.PowerAdapter,
		Percent:    78,
		Defaults: protocol.Defaults{
			Completion:  "current-all",
			PollSeconds: 5,
		},
		Candidates: []protocol.Candidate{
			{Handle: "t0001", Kind: "codex", Title: "First session", Detail: "Codex session"},
			{Handle: "p0001", Kind: "process", Title: "Worker", Detail: "PID 123"},
		},
	}
}

func TestCurrentAllFlowDoesNotCommitBeforeStart(t *testing.T) {
	m := NewModel(launcherRequest()).SkipSplash()
	m.activate(option{id: "current"})
	m.activate(option{id: "current-all"})
	if m.screen != screenSafeguards {
		t.Fatalf("screen = %v, want safeguards", m.screen)
	}
	if _, ok := m.Choice(); ok {
		t.Fatal("navigation committed a choice before Start")
	}
	m.activate(option{id: "start"})
	choice, ok := m.Choice()
	if !ok || choice.Action != "start" || choice.Completion != "current-all" {
		t.Fatalf("choice = %#v, %v", choice, ok)
	}
}

func TestSelectedFlowVisitsSafeguardsAndPreservesRequestOrder(t *testing.T) {
	m := NewModel(launcherRequest()).SkipSplash()
	m.activate(option{id: "current"})
	m.activate(option{id: "current-selected"})
	m.selected["p0001"] = true
	m.selected["t0001"] = true
	m.activate(option{id: "continue"})
	if m.screen != screenSafeguards {
		t.Fatalf("screen = %v, want safeguards", m.screen)
	}
	m.activate(option{id: "start"})
	choice, ok := m.Choice()
	if !ok || choice.Completion != "current-selected" {
		t.Fatalf("choice = %#v, %v", choice, ok)
	}
	if strings.Join(choice.Targets, ",") != "t0001,p0001" {
		t.Fatalf("targets = %v", choice.Targets)
	}
}

func TestTimerPresetAndCustomAdvanceToSafeguards(t *testing.T) {
	for _, test := range []struct {
		name    string
		seconds int
		custom  bool
	}{{"preset", 7200, false}, {"custom", 123, true}} {
		t.Run(test.name, func(t *testing.T) {
			m := NewModel(launcherRequest()).SkipSplash()
			m.activate(option{id: "timer"})
			if test.custom {
				m.activate(option{id: "timeout-custom"})
				m.numberValue = "123"
				m.commitNumber()
			} else {
				m.activate(option{id: "timeout-7200"})
			}
			if m.screen != screenSafeguards || m.timeout != test.seconds {
				t.Fatalf("screen = %v timeout = %d", m.screen, m.timeout)
			}
			m.activate(option{id: "start"})
			choice, ok := m.Choice()
			if !ok || choice.Completion != "timer" || choice.TimeoutSeconds != test.seconds {
				t.Fatalf("choice = %#v, %v", choice, ok)
			}
		})
	}
}

func TestManualWithoutSafeguardsRequiresConfirmation(t *testing.T) {
	m := NewModel(launcherRequest()).SkipSplash()
	m.activate(option{id: "manual"})
	m.activate(option{id: "start"})
	if m.screen != screenConfirm {
		t.Fatalf("screen = %v, want confirmation", m.screen)
	}
	if _, ok := m.Choice(); ok {
		t.Fatal("indefinite manual mode started without confirmation")
	}
	m.activate(option{id: "confirm-start"})
	choice, ok := m.Choice()
	if !ok || choice.Completion != "manual" {
		t.Fatalf("choice = %#v, %v", choice, ok)
	}
}

func TestInvalidConfiguredBatteryFloorBlocksStartUntilResolved(t *testing.T) {
	request := launcherRequest()
	request.Power = protocol.PowerUnknown
	request.Percent = -1
	request.Defaults.MinBattery = 25
	m := NewModel(request).SkipSplash()
	m.activate(option{id: "manual"})
	start := m.options()[2]
	if !start.disabled || !strings.Contains(start.detail, "unavailable") {
		t.Fatalf("invalid battery floor did not disable Start: %#v", start)
	}
	m.activate(option{id: "start"})
	if _, ok := m.Choice(); ok {
		t.Fatal("invalid battery floor was allowed to start")
	}
	m.activate(option{id: "battery"})
	m.activate(option{id: "battery-off"})
	if m.screen != screenSafeguards || !m.batteryConfigValid() {
		t.Fatalf("battery floor could not be resolved: screen=%v min=%d", m.screen, m.minBattery)
	}
}

func TestCurrentModeIsUnavailableWithoutDetectedCandidates(t *testing.T) {
	request := launcherRequest()
	request.Candidates = nil
	m := NewModel(request).SkipSplash()
	m.activate(option{id: "current"})
	options := m.options()
	if !options[0].disabled || !options[1].disabled {
		t.Fatalf("empty candidate choices are enabled: %#v", options)
	}
}

func TestQuitKeyOnlyExitsAtRoot(t *testing.T) {
	m := NewModel(launcherRequest()).SkipSplash()
	m.push(screenHelp)
	m.updateMenu("q")
	if _, ok := m.Choice(); ok {
		t.Fatal("q exited from a nested screen")
	}
	m.pop()
	m.updateMenu("q")
	choice, ok := m.Choice()
	if !ok || choice.Action != "quit" {
		t.Fatalf("choice = %#v, %v", choice, ok)
	}
}

func TestRenderRespectsTerminalGeometry(t *testing.T) {
	for _, size := range []struct{ width, height int }{{20, 5}, {80, 20}, {120, 30}, {200, 60}} {
		m := NewModel(launcherRequest()).SkipSplash()
		m.width, m.height = size.width, size.height
		frame := m.Render()
		lines := strings.Split(frame, "\n")
		if len(lines) > size.height {
			t.Fatalf("%dx%d frame has %d rows", size.width, size.height, len(lines))
		}
		for row, line := range lines {
			if cells := ansi.StringWidth(line); cells > size.width {
				t.Fatalf("%dx%d row %d uses %d cells: %q", size.width, size.height, row, cells, line)
			}
		}
		if size.height >= 5 && !strings.Contains(frame, "Ente") {
			t.Fatalf("%dx%d frame omitted the control hint: %q", size.width, size.height, frame)
		}
	}
}

func TestScrolledListKeepsSelectedOptionVisible(t *testing.T) {
	m := NewModel(launcherRequest()).SkipSplash()
	m.screen = screenMain
	m.width, m.height = 80, 13
	m.cursors[screenMain] = len(m.options()) - 1
	frame := m.Render()
	if !strings.Contains(frame, "> Quit") {
		t.Fatalf("scrolled frame hid the selected option:\n%s", frame)
	}
}

func TestMinimalNumberViewKeepsInputVisible(t *testing.T) {
	m := NewModel(launcherRequest()).SkipSplash()
	m.screen = screenNumber
	m.numberValue = "25"
	m.width, m.height = 20, 5
	frame := m.Render()
	if !strings.Contains(frame, "> 25_") || !strings.Contains(frame, "Enter") {
		t.Fatalf("minimal numeric view omitted input or controls: %q", frame)
	}
}

func TestWideSplashIncludesPlainTextProductName(t *testing.T) {
	m := NewModel(launcherRequest())
	m.width, m.height = 80, 20
	if frame := m.Render(); !strings.Contains(frame, "AGENTIC MODE") {
		t.Fatalf("splash omitted plain-text product name:\n%s", frame)
	}
}
