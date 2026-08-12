package textutil

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func TestSanitizeNeutralizesTerminalAndBidiControls(t *testing.T) {
	got := Sanitize("hello\x1b[31m\nworld\u202e!")
	if got != "hello?[31m world?!" {
		t.Fatalf("Sanitize() = %q", got)
	}
	if strings.ContainsRune(got, '\x1b') || strings.ContainsRune(got, '\n') {
		t.Fatalf("Sanitize() retained a terminal control: %q", got)
	}
}

func TestClipUsesDisplayCellsAndASCIIEllipsis(t *testing.T) {
	got := Clip("agentic 日本語 session title", 14)
	if ansi.StringWidth(got) > 14 {
		t.Fatalf("Clip() width = %d, want <= 14: %q", ansi.StringWidth(got), got)
	}
	if !strings.HasSuffix(got, "...") {
		t.Fatalf("Clip() = %q, want ASCII ellipsis", got)
	}
	if got := Clip("abcdef", 3); got != "abc" {
		t.Fatalf("tiny Clip() = %q, want hard clip", got)
	}
}
