package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ariakalantari/agenticmode/internal/protocol"
)

func requestText() string {
	encode := func(value string) string { return base64.StdEncoding.EncodeToString([]byte(value)) }
	return "agenticmode-menu-v1\n" +
		"generation|1\n" +
		"system|inactive\n" +
		"power|adapter|78\n" +
		"defaults|current-all|0|0|5\n" +
		"candidate|t0001|codex|" + encode("A long responsive session title") + "|" + encode("Codex session") + "\n" +
		"end\n"
}

func writeRequest(t *testing.T, root string) string {
	t.Helper()
	path := filepath.Join(root, "request")
	if err := os.WriteFile(path, []byte(requestText()), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestVersionAndProtocolVersion(t *testing.T) {
	for _, test := range []struct{ arg, want string }{{"--version", "agenticmode-ui 1.4.0\n"}, {"--protocol-version", "1\n"}} {
		var out bytes.Buffer
		if err := run([]string{test.arg}, &out); err != nil {
			t.Fatal(err)
		}
		if out.String() != test.want {
			t.Fatalf("%s output = %q", test.arg, out.String())
		}
	}
}

func TestRenderCommandIsResponsiveAndSingleLineSafe(t *testing.T) {
	root := t.TempDir()
	request := writeRequest(t, root)
	for _, size := range []struct{ width, height string }{{"20", "5"}, {"80", "20"}, {"120", "30"}, {"200", "60"}} {
		var out bytes.Buffer
		if err := run([]string{"render", request, size.width, size.height}, &out); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(out.String(), "Keep awake") && size.width != "20" {
			t.Fatalf("render %sx%s omitted main heading:\n%s", size.width, size.height, out.String())
		}
		if strings.Contains(out.String(), "\x1b[31m") {
			t.Fatal("render retained unsafe backend escape sequence")
		}
	}
}

func TestRequestFileSafety(t *testing.T) {
	root := t.TempDir()
	request := writeRequest(t, root)
	if err := os.Chmod(request, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readRequest(request); err == nil {
		t.Fatal("readRequest accepted a group/world-readable request")
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(request, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readRequest(link); err == nil {
		t.Fatal("readRequest accepted a symlink")
	}
}

func TestWriteResponseIsOwnerOnlyAndNoOverwrite(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "response")
	choice := protocol.Choice{Generation: 1, Action: "quit"}
	if err := writeResponse(path, choice); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("response mode = %o", info.Mode().Perm())
	}
	if err := writeResponse(path, choice); err == nil {
		t.Fatal("writeResponse overwrote an existing response")
	}
}
