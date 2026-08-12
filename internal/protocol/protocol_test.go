package protocol

import (
	"bytes"
	"encoding/base64"
	"strings"
	"testing"
)

func validRequest() string {
	title := base64.StdEncoding.EncodeToString([]byte("Resize the terminal"))
	detail := base64.StdEncoding.EncodeToString([]byte("Codex session"))
	return RequestHeader + "\n" +
		"generation|1\n" +
		"system|inactive\n" +
		"power|adapter|78\n" +
		"defaults|current-all|28800|25|5\n" +
		"candidate|t0001|codex|" + title + "|" + detail + "\n" +
		"end\n"
}

func TestParseRequest(t *testing.T) {
	req, err := ParseRequest(strings.NewReader(validRequest()))
	if err != nil {
		t.Fatal(err)
	}
	if req.Generation != 1 || req.System != SystemInactive || req.Percent != 78 {
		t.Fatalf("unexpected request: %#v", req)
	}
	if len(req.Candidates) != 1 || req.Candidates[0].Title != "Resize the terminal" {
		t.Fatalf("unexpected candidates: %#v", req.Candidates)
	}
}

func TestParseRequestRejectsMalformedInput(t *testing.T) {
	tests := map[string]string{
		"duplicate scalar": strings.Replace(validRequest(), "system|inactive\n", "system|inactive\nsystem|active\n", 1),
		"unknown field":    strings.Replace(validRequest(), "end\n", "surprise|yes\nend\n", 1),
		"trailing content": validRequest() + "action|start\n",
		"bad base64":       strings.Replace(validRequest(), base64.StdEncoding.EncodeToString([]byte("Resize the terminal")), "!!!", 1),
		"leading zero":     strings.Replace(validRequest(), "power|adapter|78", "power|adapter|078", 1),
		"no final newline": strings.TrimSuffix(validRequest(), "\n"),
	}
	for name, input := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseRequest(strings.NewReader(input)); err == nil {
				t.Fatal("ParseRequest unexpectedly succeeded")
			}
		})
	}
}

func TestParseRequestSanitizesCandidateText(t *testing.T) {
	bad := base64.StdEncoding.EncodeToString([]byte("title\x1b[31m\nnext"))
	input := strings.Replace(validRequest(), base64.StdEncoding.EncodeToString([]byte("Resize the terminal")), bad, 1)
	req, err := ParseRequest(strings.NewReader(input))
	if err != nil {
		t.Fatal(err)
	}
	if req.Candidates[0].Title != "title?[31m next" {
		t.Fatalf("sanitized title = %q", req.Candidates[0].Title)
	}
}

func TestWriteChoice(t *testing.T) {
	choice := Choice{
		Generation: 1, Action: "start", Completion: "current-selected",
		Targets: []string{"t0001", "t0002"}, TimeoutSeconds: 28800, MinBattery: 25,
	}
	var out bytes.Buffer
	if err := WriteChoice(&out, choice); err != nil {
		t.Fatal(err)
	}
	want := ResponseHeader + "\n" +
		"generation|1\n" +
		"action|start\n" +
		"completion|current-selected\n" +
		"target|t0001\n" +
		"target|t0002\n" +
		"timeout-seconds|28800\n" +
		"min-battery|25\n" +
		"end\n"
	if out.String() != want {
		t.Fatalf("response:\n%s\nwant:\n%s", out.String(), want)
	}
}

func TestChoiceValidation(t *testing.T) {
	invalid := []Choice{
		{Generation: 1, Action: "start", Completion: "timer"},
		{Generation: 1, Action: "start", Completion: "current-selected"},
		{Generation: 1, Action: "start", Completion: "manual", Targets: []string{"t1"}},
		{Generation: 1, Action: "quit", TimeoutSeconds: 1},
		{Generation: 1, Action: "start", Completion: "process-selected", Targets: []string{"bad|handle"}},
	}
	for _, choice := range invalid {
		if err := choice.Validate(); err == nil {
			t.Fatalf("Validate unexpectedly accepted %#v", choice)
		}
	}
}
