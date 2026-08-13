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
	m := NewModel(launcherRequest())
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
	m := NewModel(launcherRequest())
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
			m := NewModel(launcherRequest())
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
	m := NewModel(launcherRequest())
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
	m := NewModel(request)
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
	m := NewModel(request)
	m.activate(option{id: "current"})
	options := m.options()
	if !options[0].disabled || !options[1].disabled {
		t.Fatalf("empty candidate choices are enabled: %#v", options)
	}
}

func TestQuitKeyOnlyExitsAtRoot(t *testing.T) {
	m := NewModel(launcherRequest())
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

func TestLauncherIsInteractiveOnFirstFrame(t *testing.T) {
	m := NewModel(launcherRequest())
	if m.screen != screenMain {
		t.Fatalf("initial screen = %v, want main menu", m.screen)
	}
	m.updateMenu("down")
	if m.cursor() != 1 {
		t.Fatalf("first key did not move the menu cursor: %d", m.cursor())
	}
}

func TestShimmerKeepsAnimating(t *testing.T) {
	m := NewModel(launcherRequest())
	m.noColor = false
	m.reducedMotion = false
	m.width, m.height = 80, 20
	m.frame = 8
	before := m.Render()
	updated, command := m.Update(tickMsg{})
	m = updated.(Model)
	if m.frame != 9 {
		t.Fatalf("continuing shimmer frame = %d, want 9", m.frame)
	}
	if command == nil {
		t.Fatal("shimmer stopped scheduling ticks after a complete cycle")
	}
	if after := m.Render(); after == before {
		t.Fatal("shimmer tick did not change the rendered frame")
	}
}

func TestRenderRespectsTerminalGeometry(t *testing.T) {
	for _, size := range []struct{ width, height int }{{20, 5}, {80, 20}, {120, 30}, {200, 60}} {
		m := NewModel(launcherRequest())
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

func TestMenusUseStableLeftInset(t *testing.T) {
	for _, size := range []struct{ width, height int }{{20, 5}, {80, 20}, {160, 40}} {
		m := NewModel(launcherRequest())
		m.width, m.height = size.width, size.height
		frame := m.Render()
		found := false
		for _, line := range strings.Split(frame, "\n") {
			if !strings.Contains(line, "Keep awake") {
				continue
			}
			found = true
			if !strings.HasPrefix(line, "  ") || strings.HasPrefix(line, "   ") {
				t.Fatalf("%dx%d heading is not anchored at column 3: %q", size.width, size.height, line)
			}
		}
		if !found {
			t.Fatalf("%dx%d frame omitted its heading:\n%s", size.width, size.height, frame)
		}
	}
}

func TestScrolledListKeepsSelectedOptionVisible(t *testing.T) {
	m := NewModel(launcherRequest())
	m.screen = screenMain
	m.width, m.height = 80, 13
	m.cursors[screenMain] = len(m.options()) - 1
	frame := m.Render()
	if !strings.Contains(frame, "> Quit") {
		t.Fatalf("scrolled frame hid the selected option:\n%s", frame)
	}
}

func TestMenuShowsThreeBottomAlignedRowsWithInlineDetails(t *testing.T) {
	m := NewModel(launcherRequest())
	m.width, m.height = 80, 20
	lines := strings.Split(ansi.Strip(m.Render()), "\n")
	if len(lines) != m.height {
		t.Fatalf("frame has %d rows, want %d", len(lines), m.height)
	}
	menu := lines[len(lines)-3:]
	want := []struct{ label, detail string }{
		{"Current agents finish", "Detected agents"},
		{"I turn it off", "Until turned off"},
		{"A timer expires", "Fixed duration"},
	}
	for index, item := range want {
		if !strings.Contains(menu[index], item.label) || !strings.Contains(menu[index], item.detail) {
			t.Fatalf("menu row %d does not contain inline label and detail: %q", index, menu[index])
		}
		if !strings.HasSuffix(strings.TrimRight(menu[index], " "), item.detail) {
			t.Fatalf("menu row %d detail is not right aligned: %q", index, menu[index])
		}
	}
	if strings.Contains(strings.Join(menu, "\n"), "Selected processes") {
		t.Fatalf("menu rendered more than three options:\n%s", strings.Join(menu, "\n"))
	}
}

func TestThreeRowMenuScrollsToKeepCursorVisible(t *testing.T) {
	m := NewModel(launcherRequest())
	m.width, m.height = 80, 20
	m.cursors[screenMain] = len(m.options()) - 1
	lines := strings.Split(ansi.Strip(m.Render()), "\n")
	menu := strings.Join(lines[len(lines)-3:], "\n")
	if !strings.Contains(menu, "Status") || !strings.Contains(menu, "Utilities") || !strings.Contains(menu, "> Quit") {
		t.Fatalf("scrolled viewport does not show the final three options:\n%s", menu)
	}
	if strings.Contains(menu, "A timer expires") {
		t.Fatalf("scrolled viewport retained an option above its three-row window:\n%s", menu)
	}
}

func TestWordmarkPersistsAcrossMenus(t *testing.T) {
	m := NewModel(launcherRequest())
	m.width, m.height = 80, 20
	m.push(screenUtilities)
	frame := ansi.Strip(m.Render())
	if !strings.Contains(frame, "AGENTIC MODE") || !strings.Contains(frame, "Utilities") {
		t.Fatalf("nested menu omitted persistent wordmark or heading:\n%s", frame)
	}
	if first := strings.Split(frame, "\n")[0]; strings.TrimSpace(first) == "" {
		t.Fatalf("wordmark is not top aligned:\n%s", frame)
	}
}

func TestWordmarkBlocksShareVisualCenter(t *testing.T) {
	m := NewModel(launcherRequest())
	m.noColor = true
	lines := m.renderBrand(109, 33)
	agenticLeft, agenticRight := textBounds(lines[:5])
	modeLeft, modeRight := textBounds(lines[6:11])
	delta := (agenticLeft + agenticRight) - (modeLeft + modeRight)
	if delta < -1 || delta > 1 {
		t.Fatalf("wordmark centers differ: AGENTIC %d..%d, MODE %d..%d", agenticLeft, agenticRight, modeLeft, modeRight)
	}
	compact := m.renderBrand(40, 10)
	agenticLeft, agenticRight = textBounds(compact[:1])
	modeLeft, modeRight = textBounds(compact[1:])
	delta = (agenticLeft + agenticRight) - (modeLeft + modeRight)
	if delta < -1 || delta > 1 {
		t.Fatalf("compact wordmark centers differ: AGENTIC %d..%d, MODE %d..%d", agenticLeft, agenticRight, modeLeft, modeRight)
	}
}

func textBounds(lines []string) (int, int) {
	left, right := -1, -1
	for _, line := range lines {
		line = ansi.Strip(line)
		for column, char := range line {
			if char == ' ' {
				continue
			}
			if left < 0 || column < left {
				left = column
			}
			if column > right {
				right = column
			}
		}
	}
	return left, right
}

func TestMinimalNumberViewKeepsInputVisible(t *testing.T) {
	m := NewModel(launcherRequest())
	m.screen = screenNumber
	m.numberValue = "25"
	m.width, m.height = 20, 5
	frame := m.Render()
	if !strings.Contains(frame, "> 25_") || !strings.Contains(frame, "Enter") {
		t.Fatalf("minimal numeric view omitted input or controls: %q", frame)
	}
}

func TestWideMenuIncludesPlainTextProductName(t *testing.T) {
	m := NewModel(launcherRequest())
	m.width, m.height = 80, 20
	if frame := m.Render(); !strings.Contains(frame, "AGENTIC MODE") {
		t.Fatalf("menu omitted plain-text product name:\n%s", frame)
	}
}
