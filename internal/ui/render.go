package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/ariakalantari/agenticmode/internal/protocol"
	"github.com/ariakalantari/agenticmode/internal/textutil"
)

type palette struct {
	brand    lipgloss.Style
	heading  lipgloss.Style
	selected lipgloss.Style
	dim      lipgloss.Style
	good     lipgloss.Style
	warn     lipgloss.Style
	error    lipgloss.Style
}

func (m Model) styles() palette {
	if m.noColor {
		return palette{
			brand: lipgloss.NewStyle().Bold(true), heading: lipgloss.NewStyle().Bold(true),
			selected: lipgloss.NewStyle().Bold(true), dim: lipgloss.NewStyle().Faint(true),
			good: lipgloss.NewStyle().Bold(true), warn: lipgloss.NewStyle().Bold(true), error: lipgloss.NewStyle().Bold(true),
		}
	}
	return palette{
		brand:    lipgloss.NewStyle().Foreground(lipgloss.Color("#38D9E6")).Bold(true),
		heading:  lipgloss.NewStyle().Foreground(lipgloss.Color("#F3F5F7")).Bold(true),
		selected: lipgloss.NewStyle().Foreground(lipgloss.Color("#5EE6A8")).Bold(true),
		dim:      lipgloss.NewStyle().Foreground(lipgloss.Color("#7D8794")),
		good:     lipgloss.NewStyle().Foreground(lipgloss.Color("#5EE6A8")).Bold(true),
		warn:     lipgloss.NewStyle().Foreground(lipgloss.Color("#EACB64")).Bold(true),
		error:    lipgloss.NewStyle().Foreground(lipgloss.Color("#FF6B6B")).Bold(true),
	}
}

// Render returns a complete frame derived only from the current model and
// terminal geometry. All backend-provided content is clipped to one row.
func (m Model) Render() string {
	if m.screen == screenSplash {
		return m.renderSplash()
	}
	width, height := m.width, m.height
	if width < 1 {
		width = 1
	}
	if height < 1 {
		height = 1
	}
	if height < 9 || width < 24 {
		return m.renderMinimal(width, height)
	}
	leftInset, rightInset := menuInsets(width)
	innerWidth := width - leftInset - rightInset
	if innerWidth < 1 {
		innerWidth = width
	}
	bodyHeight := height - 4
	if bodyHeight < 1 {
		bodyHeight = 1
	}

	content := m.renderContent(innerWidth, bodyHeight)
	content = constrain(content, innerWidth, bodyHeight)
	return placeMenu(width, height, leftInset, content)
}

func (m Model) renderMinimal(width, height int) string {
	leftInset, rightInset := menuInsets(width)
	contentWidth := width - leftInset - rightInset
	if contentWidth < 1 {
		contentWidth = width
		leftInset = 0
	}
	styles := m.styles()
	heading, _ := m.heading()
	lines := []string{styles.heading.Render(textutil.Clip(heading, contentWidth))}
	if m.screen == screenNumber {
		if height >= 3 {
			lines = append(lines, textutil.Clip("> "+m.numberValue+"_", contentWidth))
		}
		if height >= 4 && m.numberError != "" {
			lines = append(lines, styles.error.Render(textutil.Clip(m.numberError, contentWidth)))
		}
		if height >= 5 {
			lines = append(lines, styles.dim.Render(textutil.Clip("Enter  Esc back", contentWidth)))
		}
		return placeMenu(width, height, leftInset, constrain(strings.Join(lines, "\n"), contentWidth, height))
	}
	options := m.options()
	if height >= 3 && len(options) > 0 {
		cursor := m.cursor()
		if cursor >= len(options) {
			cursor = len(options) - 1
		}
		lines = append(lines, styles.selected.Render(textutil.Clip("> "+options[cursor].label, contentWidth)))
	}
	if height >= 5 {
		lines = append(lines, styles.dim.Render(textutil.Clip("Move j/k  Enter", contentWidth)))
	}
	return placeMenu(width, height, leftInset, constrain(strings.Join(lines, "\n"), contentWidth, height))
}

func (m Model) renderContent(width, height int) string {
	styles := m.styles()
	heading, subtitle := m.heading()
	lines := []string{}
	if height >= 6 {
		lines = append(lines, styles.brand.Render(textutil.Clip("AGENTIC / MODE", width)))
	}
	lines = append(lines, styles.heading.Render(textutil.Clip(heading, width)))
	if subtitle != "" && height >= 8 {
		lines = append(lines, styles.dim.Render(textutil.Clip(subtitle, width)))
	}

	if m.screen == screenHelp {
		lines = append(lines, "")
		lines = append(lines, m.helpLines(width, height-len(lines)-1)...)
		return strings.Join(lines, "\n")
	}
	if m.screen == screenNumber {
		lines = append(lines, "", textutil.Clip("> "+m.numberValue+"_", width))
		if m.numberError != "" {
			lines = append(lines, styles.error.Render(textutil.Clip(m.numberError, width)))
		}
		lines = append(lines, "", styles.dim.Render(textutil.Clip("Enter confirm  Esc back  Ctrl+C cancel", width)))
		return strings.Join(lines, "\n")
	}

	if (m.screen == screenSafeguards || m.screen == screenBattery) && height >= 13 {
		lines = append(lines, "", m.renderBatteryBar(width))
	}
	lines = append(lines, "")
	options := m.options()
	available := height - len(lines) - 2
	if available < 1 {
		available = 1
	}
	listLines := m.renderOptions(options, width, available)
	lines = append(lines, listLines...)
	if len(lines) < height {
		lines = append(lines, "")
		lines = append(lines, styles.dim.Render(textutil.Clip(m.footer(), width)))
	}
	return strings.Join(lines, "\n")
}

func (m Model) heading() (string, string) {
	switch m.screen {
	case screenMain:
		switch m.request.System {
		case protocol.SystemActive:
			return "Agenticmode is active", "Choose status or restore normal sleep."
		case protocol.SystemRecovery:
			return "Recovery needed", "Starting another lease is disabled."
		default:
			return "Keep awake until...", "Choose what ends the awake lease."
		}
	case screenCurrent:
		return "Current agents", "Track every detected agent or choose exact sessions."
	case screenCurrentSelect:
		return "Choose agents", "Space toggles  a selects all  Enter continues"
	case screenProcessSelect:
		return "Choose processes", "Exact PID identities are validated again by Bash."
	case screenSafeguards:
		return "Safeguards", "Optional limits may end the lease earlier."
	case screenBattery:
		return "Battery floor", powerDescription(m.request)
	case screenTimeout:
		if m.completion == "timer" {
			return "Timer duration", "Choose how long the awake lease lasts."
		}
		return "Maximum duration", "Stop even if tracked work remains active."
	case screenNumber:
		if m.numberKind == numberBattery {
			return "Custom battery floor", "Enter a percentage from 1 to 100."
		}
		return "Custom duration", "Enter seconds from 1 to 31536000."
	case screenConfirm:
		return "Start indefinite mode?", "This disables system sleep. Keep the Mac ventilated."
	case screenUtilities:
		return "Utilities", "These dispatch the existing Bash commands."
	case screenHelp:
		return "Keyboard help", "The launcher never changes power until Start is confirmed."
	default:
		return "Agenticmode", ""
	}
}

func (m Model) renderOptions(options []option, width, rows int) []string {
	if len(options) == 0 {
		return []string{m.styles().dim.Render(textutil.Clip("Nothing available.", width))}
	}
	cursor := m.cursor()
	start := 0
	if cursor >= rows {
		start = cursor - rows + 1
	}
	end := start + rows
	if end > len(options) {
		end = len(options)
		start = end - rows
		if start < 0 {
			start = 0
		}
	}
	styles := m.styles()
	result := make([]string, 0, rows)
	for index := start; index < end; index++ {
		item := options[index]
		prefix := "  "
		if index == cursor {
			prefix = "> "
		}
		if (m.screen == screenCurrentSelect || m.screen == screenProcessSelect) && item.id != "continue" && item.id != "back" {
			if m.selected[item.id] {
				prefix += "[x] "
			} else {
				prefix += "[ ] "
			}
		}
		label := textutil.Clip(prefix+item.label, width)
		switch {
		case item.disabled:
			label = styles.dim.Render(label)
		case index == cursor:
			label = styles.selected.Render(label)
		}
		result = append(result, label)
		if index == cursor && rows-len(result) > 0 && item.detail != "" && rows >= 4 {
			result = append(result, styles.dim.Render(textutil.Clip("    "+item.detail, width)))
		}
	}
	if start > 0 && len(result) > 0 && start != cursor {
		result[0] = styles.dim.Render(textutil.Clip(fmt.Sprintf("... %d above", start), width))
	}
	if end < len(options) && len(result) > 0 && end-1 != cursor {
		result[len(result)-1] = styles.dim.Render(textutil.Clip(fmt.Sprintf("... %d more", len(options)-end), width))
	}
	return result
}

func (m Model) renderBatteryBar(width int) string {
	styles := m.styles()
	if m.request.Power == protocol.PowerUnknown {
		return styles.warn.Render(textutil.Clip("Battery: unavailable", width))
	}
	barWidth := width - 12
	if barWidth > 48 {
		barWidth = 48
	}
	if barWidth < 8 {
		return textutil.Clip(fmt.Sprintf("Battery %d%%", m.request.Percent), width)
	}
	filled := m.request.Percent * barWidth / 100
	marker := -1
	if m.minBattery > 0 {
		marker = m.minBattery * barWidth / 100
		if marker >= barWidth {
			marker = barWidth - 1
		}
	}
	var bar strings.Builder
	bar.WriteByte('[')
	for index := 0; index < barWidth; index++ {
		switch {
		case index == marker:
			bar.WriteByte('|')
		case index < filled:
			bar.WriteByte('=')
		default:
			bar.WriteByte('-')
		}
	}
	bar.WriteString(fmt.Sprintf("] %d%%", m.request.Percent))
	return styles.good.Render(textutil.Clip(bar.String(), width))
}

func (m Model) footer() string {
	if m.screen == screenCurrentSelect || m.screen == screenProcessSelect {
		return "Arrows/j/k move  Space toggle  a all  Enter choose  Esc back  ? help"
	}
	return "Arrows/j/k move  Enter choose  Esc back  ? help  Ctrl+C cancel"
}

func (m Model) helpLines(width, rows int) []string {
	items := []string{
		"Up/Down or j/k   Move selection",
		"Enter            Choose",
		"Space            Toggle a target",
		"a                Select or clear all targets",
		"Escape           Go back",
		"Ctrl+L           Redraw the terminal",
		"Ctrl+C           Cancel without changing power",
		"q                Quit from the root menu",
		"?                Close this help",
	}
	if rows < len(items) {
		items = items[:max(rows, 1)]
	}
	for index := range items {
		items[index] = textutil.Clip(items[index], width)
	}
	return items
}

func (m Model) renderSplash() string {
	width, height := m.width, m.height
	if width < 1 {
		width = 1
	}
	if height < 1 {
		height = 1
	}
	if width < 48 || height < 15 {
		content := m.styles().brand.Render(textutil.Clip("AGENTIC\nMODE", width))
		return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, content)
	}
	mask := []string{
		"  A   GGG  EEEEE N   N TTTTT IIIII  CCCC",
		" A A G     E     NN  N   T     I   C    ",
		"AAAAAG  GG EEEE  N N N   T     I   C    ",
		"A   AG   G E     N  NN   T     I   C    ",
		"A   A GGG  EEEEE N   N   T   IIIII  CCCC",
		"",
		"             M   M  OOO  DDDD  EEEEE",
		"             MM MM O   O D   D E    ",
		"             M M M O   O D   D EEEE ",
		"             M   M O   O D   D E    ",
		"             M   M  OOO  DDDD  EEEEE",
	}
	lines := make([]string, len(mask))
	for row, line := range mask {
		lines[row] = m.shimmer(line, row)
	}
	content := strings.Join(lines, "\n")
	// Keep the product name available as plain text for screen readers, logs,
	// and terminals whose font makes the block-art lettering ambiguous.
	content += "\n" + m.styles().dim.Render("AGENTIC MODE")
	return lipgloss.Place(width, height, lipgloss.Center, lipgloss.Center, content)
}

func (m Model) shimmer(line string, row int) string {
	if m.noColor || m.reducedMotion {
		return line
	}
	var result strings.Builder
	phase := (m.frame*7 + row) % 55
	for column, r := range line {
		style := lipgloss.NewStyle().Foreground(lipgloss.Color("#178A9A"))
		distance := column - phase
		if distance < 0 {
			distance = -distance
		}
		if r != ' ' && distance <= 2 {
			style = lipgloss.NewStyle().Foreground(lipgloss.Color("#E9FFF6")).Bold(true)
		} else if r != ' ' && distance <= 6 {
			style = lipgloss.NewStyle().Foreground(lipgloss.Color("#5EE6A8")).Bold(true)
		}
		result.WriteString(style.Render(string(r)))
	}
	return result.String()
}

func powerDescription(req protocol.Request) string {
	switch req.Power {
	case protocol.PowerAdapter:
		return fmt.Sprintf("On adapter at %d%%; the floor activates on battery.", req.Percent)
	case protocol.PowerBattery:
		return fmt.Sprintf("Currently on battery at %d%%.", req.Percent)
	default:
		return "Battery state is unavailable; a floor cannot be enabled."
	}
}

func constrain(content string, width, height int) string {
	lines := strings.Split(content, "\n")
	if len(lines) > height {
		lines = lines[:height]
	}
	for index, line := range lines {
		if ansi.StringWidth(line) > width {
			// Content is clipped before styling throughout the renderer. This is a
			// defensive final guard for static strings and future additions.
			lines[index] = ansi.Truncate(line, width, "")
		}
	}
	return strings.Join(lines, "\n")
}

func menuInsets(width int) (int, int) {
	if width < 5 {
		return 0, 0
	}
	return 2, 2
}

func placeMenu(width, height, leftInset int, content string) string {
	if leftInset > 0 {
		prefix := strings.Repeat(" ", leftInset)
		lines := strings.Split(content, "\n")
		for index, line := range lines {
			if line != "" {
				lines[index] = prefix + line
			}
		}
		content = strings.Join(lines, "\n")
	}
	return lipgloss.Place(width, height, lipgloss.Left, lipgloss.Center, content)
}
