package textutil

import (
	"strings"
	"unicode"

	"github.com/charmbracelet/x/ansi"
)

// Sanitize returns one printable terminal line. It deliberately neutralizes
// control bytes and bidirectional formatting characters before any styling is
// applied, so backend-provided titles can never become terminal instructions.
func Sanitize(value string) string {
	var out strings.Builder
	for _, r := range value {
		switch {
		case r == '\n' || r == '\r' || r == '\t':
			out.WriteByte(' ')
		case r < 0x20 || (r >= 0x7f && r <= 0x9f):
			out.WriteByte('?')
		case r == 0x200e || r == 0x200f || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069):
			out.WriteByte('?')
		case unicode.IsControl(r):
			out.WriteByte('?')
		default:
			out.WriteRune(r)
		}
	}
	return strings.TrimSpace(out.String())
}

// Clip truncates by terminal display cells and always uses an ASCII ellipsis.
// Tiny widths hard-clip because an ellipsis cannot fit meaningfully.
func Clip(value string, width int) string {
	if width <= 0 {
		return ""
	}
	value = Sanitize(value)
	if ansi.StringWidth(value) <= width {
		return value
	}
	if width < 4 {
		return ansi.Truncate(value, width, "")
	}
	return ansi.Truncate(value, width, "...")
}
