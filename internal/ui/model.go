package ui

import (
	"fmt"
	"os"
	"strconv"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/ariakalantari/agenticmode/internal/protocol"
)

type screen int

const (
	screenSplash screen = iota
	screenMain
	screenCurrent
	screenCurrentSelect
	screenProcessSelect
	screenSafeguards
	screenBattery
	screenTimeout
	screenNumber
	screenConfirm
	screenUtilities
	screenHelp
)

type numberKind int

const (
	numberBattery numberKind = iota
	numberTimeout
)

type tickMsg time.Time

type option struct {
	id       string
	label    string
	detail   string
	disabled bool
}

// Model is a pure launcher state machine. Bash supplies all authoritative
// backend state and validates the resulting Choice again before changing power.
type Model struct {
	request       protocol.Request
	screen        screen
	stack         []screen
	cursors       map[screen]int
	selected      map[string]bool
	completion    string
	timeout       int
	minBattery    int
	choice        protocol.Choice
	hasChoice     bool
	width         int
	height        int
	frame         int
	reducedMotion bool
	noColor       bool
	numberKind    numberKind
	numberValue   string
	numberError   string
	numberAdvance bool
}

func NewModel(request protocol.Request) Model {
	reduced := os.Getenv("AGENTICMODE_REDUCED_MOTION") == "1"
	initial := screenSplash
	if reduced {
		initial = screenMain
	}
	return Model{
		request:       request,
		screen:        initial,
		cursors:       make(map[screen]int),
		selected:      make(map[string]bool),
		completion:    request.Defaults.Completion,
		timeout:       request.Defaults.TimeoutSeconds,
		minBattery:    request.Defaults.MinBattery,
		width:         80,
		height:        24,
		reducedMotion: reduced,
		noColor:       os.Getenv("NO_COLOR") != "",
	}
}

// SkipSplash returns a model positioned at the first interactive screen. It is
// used by deterministic render tests and other non-interactive previews.
func (m Model) SkipSplash() Model {
	if m.screen == screenSplash {
		m.screen = screenMain
	}
	return m
}

func (m Model) Init() tea.Cmd {
	if m.screen == screenSplash {
		return tickAfter()
	}
	return nil
}

func tickAfter() tea.Cmd {
	return tea.Tick(80*time.Millisecond, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m Model) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := message.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		if m.width < 1 {
			m.width = 1
		}
		if m.height < 1 {
			m.height = 1
		}
		m.clampCursor()
		return m, nil
	case tickMsg:
		if m.screen != screenSplash {
			return m, nil
		}
		m.frame++
		if m.frame >= 8 {
			m.screen = screenMain
			return m, nil
		}
		return m, tickAfter()
	case tea.KeyPressMsg:
		key := msg.Keystroke()
		if m.screen == screenSplash {
			m.screen = screenMain
			return m, nil // the skip key is deliberately discarded
		}
		if key == "ctrl+c" {
			m.finish(protocol.Choice{Generation: m.request.Generation, Action: "cancel"})
			return m, tea.Quit
		}
		if key == "ctrl+l" {
			return m, func() tea.Msg { return tea.ClearScreen() }
		}
		if m.screen == screenNumber {
			return m.updateNumber(key)
		}
		return m.updateMenu(key)
	}
	return m, nil
}

func (m Model) View() tea.View {
	view := tea.NewView(m.Render())
	view.AltScreen = true
	view.DisableBracketedPasteMode = true
	view.MouseMode = tea.MouseModeNone
	return view
}

func (m *Model) updateMenu(key string) (tea.Model, tea.Cmd) {
	if key == "?" {
		if m.screen == screenHelp {
			m.pop()
		} else {
			m.push(screenHelp)
		}
		return *m, nil
	}
	if key == "esc" {
		if len(m.stack) == 0 || m.screen == screenMain {
			m.finish(protocol.Choice{Generation: m.request.Generation, Action: "cancel"})
			return *m, tea.Quit
		}
		m.pop()
		return *m, nil
	}
	if key == "q" && m.screen == screenMain {
		m.finish(protocol.Choice{Generation: m.request.Generation, Action: "quit"})
		return *m, tea.Quit
	}

	options := m.options()
	cursor := m.cursor()
	switch key {
	case "up", "k":
		m.move(-1, options)
	case "down", "j":
		m.move(1, options)
	case " ":
		m.toggleSelected(options, cursor)
	case "a":
		if m.screen == screenCurrentSelect || m.screen == screenProcessSelect {
			m.toggleAll(options)
		}
	case "enter":
		if len(options) > 0 && cursor < len(options) && !options[cursor].disabled {
			return m.activate(options[cursor])
		}
	}
	return *m, nil
}

func (m *Model) updateNumber(key string) (tea.Model, tea.Cmd) {
	switch key {
	case "esc":
		m.numberError = ""
		m.pop()
	case "backspace", "ctrl+h":
		if len(m.numberValue) > 0 {
			m.numberValue = m.numberValue[:len(m.numberValue)-1]
		}
		m.numberError = ""
	case "enter":
		m.commitNumber()
	default:
		if len(key) == 1 && key[0] >= '0' && key[0] <= '9' && len(m.numberValue) < 8 {
			m.numberValue += key
			m.numberError = ""
		}
	}
	return *m, nil
}

func (m *Model) commitNumber() {
	n, err := strconv.Atoi(m.numberValue)
	if err != nil {
		m.numberError = "Enter a number."
		return
	}
	switch m.numberKind {
	case numberBattery:
		if n < 1 || n > 100 {
			m.numberError = "Battery floor must be from 1 to 100%."
			return
		}
		if m.request.Power == protocol.PowerUnknown {
			m.numberError = "Battery state is unavailable; a floor cannot be enabled."
			return
		}
		if m.request.Power == protocol.PowerBattery && n >= m.request.Percent {
			m.numberError = fmt.Sprintf("Choose less than the current %d%% charge.", m.request.Percent)
			return
		}
		m.minBattery = n
	case numberTimeout:
		if n < 1 || n > 31536000 {
			m.numberError = "Duration must be from 1 to 31536000 seconds."
			return
		}
		m.timeout = n
	}
	m.numberError = ""
	m.pop()
	if m.numberKind == numberTimeout && m.numberAdvance {
		m.numberAdvance = false
		m.finishTimeoutPicker()
	}
}

func (m *Model) activate(selected option) (tea.Model, tea.Cmd) {
	switch selected.id {
	case "current":
		m.push(screenCurrent)
	case "current-all":
		m.completion = "current-all"
		m.push(screenSafeguards)
	case "current-selected":
		m.completion = "current-selected"
		m.push(screenCurrentSelect)
	case "manual":
		m.completion = "manual"
		m.push(screenSafeguards)
	case "timer":
		m.completion = "timer"
		if m.timeout == 0 {
			m.timeout = 3600
		}
		m.push(screenTimeout)
	case "process":
		m.completion = "process-selected"
		m.push(screenProcessSelect)
	case "battery":
		m.push(screenBattery)
	case "timeout":
		m.push(screenTimeout)
	case "battery-custom":
		m.openNumber(numberBattery, m.minBattery)
	case "timeout-custom":
		m.numberAdvance = m.completion == "timer" && len(m.stack) > 0 && m.stack[len(m.stack)-1] == screenMain
		m.openNumber(numberTimeout, m.timeout)
	case "continue":
		m.push(screenSafeguards)
	case "start":
		if (m.completion == "current-selected" || m.completion == "process-selected") && len(m.selectedHandles()) == 0 {
			return *m, nil
		}
		if !m.batteryConfigValid() {
			return *m, nil
		}
		if m.completion == "manual" && m.timeout == 0 && m.minBattery == 0 {
			m.push(screenConfirm)
		} else {
			return m.completeStart()
		}
	case "confirm-start":
		return m.completeStart()
	case "back":
		m.pop()
	case "utilities":
		m.push(screenUtilities)
	case "status", "stop", "detect", "doctor", "config", "update", "help":
		m.finish(protocol.Choice{Generation: m.request.Generation, Action: selected.id})
		return *m, tea.Quit
	case "quit":
		m.finish(protocol.Choice{Generation: m.request.Generation, Action: "quit"})
		return *m, tea.Quit
	case "battery-off":
		m.minBattery = 0
		m.pop()
	case "timeout-off":
		if m.completion != "timer" {
			m.timeout = 0
			m.pop()
		}
	default:
		if value, ok := parsePreset(selected.id, "battery-"); ok {
			if m.batteryPresetAllowed(value) {
				m.minBattery = value
				m.pop()
			}
		} else if value, ok := parsePreset(selected.id, "timeout-"); ok {
			m.timeout = value
			m.finishTimeoutPicker()
		}
	}
	return *m, nil
}

func (m *Model) finishTimeoutPicker() {
	m.pop()
	if m.completion == "timer" && m.screen == screenMain {
		m.push(screenSafeguards)
	}
}

func (m *Model) completeStart() (tea.Model, tea.Cmd) {
	choice := protocol.Choice{
		Generation:     m.request.Generation,
		Action:         "start",
		Completion:     m.completion,
		TimeoutSeconds: m.timeout,
		MinBattery:     m.minBattery,
	}
	if m.completion == "current-selected" || m.completion == "process-selected" {
		choice.Targets = m.selectedHandles()
	}
	m.finish(choice)
	return *m, tea.Quit
}

func (m *Model) finish(choice protocol.Choice) {
	m.choice = choice
	m.hasChoice = true
}

func (m Model) Choice() (protocol.Choice, bool) { return m.choice, m.hasChoice }

func (m *Model) push(next screen) {
	m.stack = append(m.stack, m.screen)
	m.screen = next
	m.clampCursor()
}

func (m *Model) pop() {
	if len(m.stack) == 0 {
		m.screen = screenMain
		return
	}
	m.screen = m.stack[len(m.stack)-1]
	m.stack = m.stack[:len(m.stack)-1]
	m.clampCursor()
}

func (m *Model) openNumber(kind numberKind, current int) {
	m.numberKind = kind
	m.numberValue = ""
	if current > 0 {
		m.numberValue = strconv.Itoa(current)
	}
	m.numberError = ""
	m.push(screenNumber)
}

func (m Model) cursor() int { return m.cursors[m.screen] }

func (m *Model) clampCursor() {
	options := m.options()
	if len(options) == 0 {
		m.cursors[m.screen] = 0
		return
	}
	if m.cursors[m.screen] >= len(options) {
		m.cursors[m.screen] = len(options) - 1
	}
	if m.cursors[m.screen] < 0 {
		m.cursors[m.screen] = 0
	}
}

func (m *Model) move(delta int, options []option) {
	if len(options) == 0 {
		return
	}
	index := m.cursor()
	for attempts := 0; attempts < len(options); attempts++ {
		index = (index + delta + len(options)) % len(options)
		if !options[index].disabled {
			m.cursors[m.screen] = index
			return
		}
	}
}

func (m *Model) toggleSelected(options []option, cursor int) {
	if (m.screen != screenCurrentSelect && m.screen != screenProcessSelect) || cursor >= len(options) {
		return
	}
	if options[cursor].id == "back" || options[cursor].id == "continue" || options[cursor].disabled {
		return
	}
	m.selected[options[cursor].id] = !m.selected[options[cursor].id]
}

func (m *Model) toggleAll(options []option) {
	all := true
	for _, item := range options {
		if item.id != "continue" && item.id != "back" && !item.disabled && !m.selected[item.id] {
			all = false
		}
	}
	for _, item := range options {
		if item.id != "continue" && item.id != "back" && !item.disabled {
			m.selected[item.id] = !all
		}
	}
}

func (m Model) selectedHandles() []string {
	result := make([]string, 0)
	for _, candidate := range m.request.Candidates {
		if !m.selected[candidate.Handle] {
			continue
		}
		if m.completion == "process-selected" && candidate.Kind != "process" {
			continue
		}
		result = append(result, candidate.Handle)
	}
	return result
}

func (m Model) batteryPresetAllowed(value int) bool {
	if m.request.Power == protocol.PowerUnknown {
		return false
	}
	return m.request.Power != protocol.PowerBattery || value < m.request.Percent
}

func (m Model) batteryConfigValid() bool {
	if m.minBattery == 0 {
		return true
	}
	if m.request.Power == protocol.PowerUnknown {
		return false
	}
	return m.request.Power != protocol.PowerBattery || m.minBattery < m.request.Percent
}

func parsePreset(id, prefix string) (int, bool) {
	if len(id) <= len(prefix) || id[:len(prefix)] != prefix {
		return 0, false
	}
	value, err := strconv.Atoi(id[len(prefix):])
	return value, err == nil
}

func (m Model) options() []option {
	switch m.screen {
	case screenMain:
		switch m.request.System {
		case protocol.SystemActive:
			return []option{{"status", "View status", "Inspect the active controller and watchdog.", false}, {"stop", "Stop and restore sleep", "End the active awake lease safely.", false}, {"utilities", "Utilities", "Doctor, configuration, update, and help.", false}, {"quit", "Exit", "Leave the active lease unchanged.", false}}
		case protocol.SystemRecovery:
			return []option{{"stop", "Restore normal sleep", "Run the existing fail-closed recovery path.", false}, {"doctor", "View diagnostics", "Inspect the inconsistent controller state.", false}, {"quit", "Exit", "Make no changes.", false}}
		default:
			return []option{{"current", "Current agents finish", "Track all detected agents or choose exact sessions.", false}, {"manual", "I turn it off", "Keep awake until Ctrl+C or am off.", false}, {"timer", "A timer expires", "Choose a fixed awake duration.", false}, {"process", "Selected processes finish", "Track exact detected process identities.", m.processCount() == 0}, {"status", "Status", "Inspect sleep and controller health.", false}, {"utilities", "Utilities", "Detect, doctor, config, update, and help.", false}, {"quit", "Quit", "Make no power changes.", false}}
		}
	case screenCurrent:
		return []option{{"current-all", fmt.Sprintf("All detected agents (%d)", len(m.request.Candidates)), "Track this immutable snapshot after Bash revalidates each target.", len(m.request.Candidates) == 0}, {"current-selected", "Choose specific agents...", "Select immutable targets from the detected snapshot.", len(m.request.Candidates) == 0}, {"back", "Back", "Return to the launcher.", false}}
	case screenCurrentSelect:
		return m.candidateOptions(false)
	case screenProcessSelect:
		return m.candidateOptions(true)
	case screenSafeguards:
		return []option{{"battery", "Battery floor", batteryLabel(m.minBattery), false}, {"timeout", "Maximum duration", timeoutLabel(m.timeout), false}, {"start", "Start agenticmode", m.startSummary(), !m.batteryConfigValid() || (m.completion == "current-selected" || m.completion == "process-selected") && len(m.selectedHandles()) == 0}, {"back", "Back", "Change the completion condition.", false}}
	case screenBattery:
		result := []option{{"battery-off", "Off", "No battery cutoff.", false}}
		for _, value := range []int{15, 20, 25, 30, 40} {
			result = append(result, option{fmt.Sprintf("battery-%d", value), fmt.Sprintf("%d%%", value), batteryPresetDetail(m.request, value), !m.batteryPresetAllowed(value)})
		}
		result = append(result, option{"battery-custom", "Custom percentage...", "Enter an exact cutoff from 1 to 100%.", m.request.Power == protocol.PowerUnknown}, option{"back", "Back", "Keep the current battery floor.", false})
		return result
	case screenTimeout:
		result := []option{}
		if m.completion != "timer" {
			result = append(result, option{"timeout-off", "Off", "No maximum duration.", false})
		}
		for _, preset := range []struct {
			seconds int
			label   string
		}{{1800, "30 minutes"}, {3600, "1 hour"}, {7200, "2 hours"}, {14400, "4 hours"}, {28800, "8 hours"}} {
			result = append(result, option{fmt.Sprintf("timeout-%d", preset.seconds), preset.label, fmt.Sprintf("Stop after %s.", preset.label), false})
		}
		result = append(result, option{"timeout-custom", "Custom seconds...", "Enter 1 to 31536000 seconds.", false}, option{"back", "Back", "Keep the current duration.", false})
		return result
	case screenConfirm:
		return []option{{"confirm-start", "Start indefinite mode", "Keep awake until Ctrl+C or am off.", false}, {"back", "Back", "Add a safety limit or cancel.", false}}
	case screenUtilities:
		return []option{{"detect", "Detect current agents", "Read-only detection; no power change.", false}, {"doctor", "Doctor", "Inspect installation and runtime health.", false}, {"config", "Effective configuration", "Show the resolved backend settings.", false}, {"update", "Update", "Run the existing verified update workflow.", false}, {"help", "Command help", "Show all explicit CLI shortcuts.", false}, {"back", "Back", "Return to the launcher.", false}}
	}
	return nil
}

func (m Model) candidateOptions(processOnly bool) []option {
	result := make([]option, 0, len(m.request.Candidates)+2)
	for _, candidate := range m.request.Candidates {
		if processOnly && candidate.Kind != "process" {
			continue
		}
		result = append(result, option{candidate.Handle, candidate.Title, candidate.Detail, false})
	}
	result = append(result, option{"continue", fmt.Sprintf("Continue with %d selected", len(m.selectedHandles())), "Configure battery and time safeguards.", len(m.selectedHandles()) == 0}, option{"back", "Back", "Return without selecting targets.", false})
	return result
}

func (m Model) processCount() int {
	count := 0
	for _, candidate := range m.request.Candidates {
		if candidate.Kind == "process" {
			count++
		}
	}
	return count
}

func batteryLabel(value int) string {
	if value == 0 {
		return "Off"
	}
	return fmt.Sprintf("Stop at %d%%", value)
}

func timeoutLabel(value int) string {
	if value == 0 {
		return "Off"
	}
	return "Stop after " + formatDuration(value)
}

func formatDuration(seconds int) string {
	if seconds%3600 == 0 {
		return fmt.Sprintf("%dh", seconds/3600)
	}
	if seconds%60 == 0 {
		return fmt.Sprintf("%dm", seconds/60)
	}
	return fmt.Sprintf("%ds", seconds)
}

func batteryPresetDetail(req protocol.Request, value int) string {
	if req.Power == protocol.PowerUnknown {
		return "Battery state is unavailable."
	}
	if req.Power == protocol.PowerBattery && value >= req.Percent {
		return fmt.Sprintf("Current charge is %d%%; choose a lower floor.", req.Percent)
	}
	if req.Power == protocol.PowerAdapter {
		return "Activates after switching to battery power."
	}
	return fmt.Sprintf("Restore sleep at or below %d%%.", value)
}

func (m Model) startSummary() string {
	if !m.batteryConfigValid() {
		return "Battery floor is unavailable; choose Off or a lower floor."
	}
	var condition string
	switch m.completion {
	case "current-all":
		condition = "all current agents"
	case "current-selected", "process-selected":
		condition = fmt.Sprintf("%d selected targets", len(m.selectedHandles()))
	case "timer":
		condition = "timer"
	default:
		condition = "manual mode"
	}
	if m.minBattery > 0 {
		condition += fmt.Sprintf(", %d%% battery floor", m.minBattery)
	}
	if m.timeout > 0 {
		condition += ", " + formatDuration(m.timeout) + " maximum"
	}
	return condition
}
