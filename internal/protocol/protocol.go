package protocol

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/ariakalantari/agenticmode/internal/textutil"
)

const (
	RequestHeader   = "agenticmode-menu-v1"
	ResponseHeader  = "agenticmode-choice-v1"
	MaxRequestSize  = 1 << 20
	MaxResponseSize = 64 << 10
	MaxCandidates   = 1000
)

type SystemState string

const (
	SystemInactive SystemState = "inactive"
	SystemActive   SystemState = "active"
	SystemRecovery SystemState = "recovery"
)

type PowerSource string

const (
	PowerAdapter PowerSource = "adapter"
	PowerBattery PowerSource = "battery"
	PowerUnknown PowerSource = "unknown"
)

type Candidate struct {
	Handle string
	Kind   string
	Title  string
	Detail string
}

type Defaults struct {
	Completion     string
	TimeoutSeconds int
	MinBattery     int
	PollSeconds    int
}

type Request struct {
	Generation int
	System     SystemState
	Power      PowerSource
	Percent    int
	Defaults   Defaults
	Candidates []Candidate
}

type Choice struct {
	Generation     int
	Action         string
	Completion     string
	Targets        []string
	TimeoutSeconds int
	MinBattery     int
}

func ParseRequest(reader io.Reader) (Request, error) {
	data, err := io.ReadAll(io.LimitReader(reader, MaxRequestSize+1))
	if err != nil {
		return Request{}, fmt.Errorf("read menu request: %w", err)
	}
	if len(data) > MaxRequestSize {
		return Request{}, errors.New("menu request exceeds 1 MiB")
	}
	if len(data) == 0 || data[len(data)-1] != '\n' {
		return Request{}, errors.New("menu request must end with a newline")
	}

	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), MaxRequestSize)
	line := 0
	var req Request
	seen := map[string]bool{}
	handles := map[string]bool{}
	ended := false
	for scanner.Scan() {
		line++
		value := scanner.Text()
		if line == 1 {
			if value != RequestHeader {
				return Request{}, fmt.Errorf("line 1: unsupported request header")
			}
			continue
		}
		if ended {
			return Request{}, fmt.Errorf("line %d: content after end", line)
		}
		parts := strings.Split(value, "|")
		key := parts[0]
		switch key {
		case "generation":
			if err := uniqueScalar(seen, key, parts, 2); err != nil {
				return Request{}, lineError(line, err)
			}
			req.Generation, err = parseInt(parts[1], 1, 1, "generation")
		case "system":
			if err := uniqueScalar(seen, key, parts, 2); err != nil {
				return Request{}, lineError(line, err)
			}
			req.System = SystemState(parts[1])
			if !oneOf(parts[1], string(SystemInactive), string(SystemActive), string(SystemRecovery)) {
				err = errors.New("invalid system state")
			}
		case "power":
			if err := uniqueScalar(seen, key, parts, 3); err != nil {
				return Request{}, lineError(line, err)
			}
			req.Power = PowerSource(parts[1])
			switch req.Power {
			case PowerAdapter, PowerBattery:
				req.Percent, err = parseInt(parts[2], 0, 100, "battery percentage")
			case PowerUnknown:
				if parts[2] != "unknown" {
					err = errors.New("unknown power requires unknown percentage")
				}
				req.Percent = -1
			default:
				err = errors.New("invalid power source")
			}
		case "defaults":
			if err := uniqueScalar(seen, key, parts, 5); err != nil {
				return Request{}, lineError(line, err)
			}
			req.Defaults.Completion = parts[1]
			if !oneOf(parts[1], "current-all", "manual", "timer", "process-selected") {
				err = errors.New("invalid default completion")
				break
			}
			req.Defaults.TimeoutSeconds, err = parseInt(parts[2], 0, 31536000, "default timeout")
			if err == nil {
				req.Defaults.MinBattery, err = parseInt(parts[3], 0, 100, "default battery floor")
			}
			if err == nil {
				req.Defaults.PollSeconds, err = parseInt(parts[4], 1, 300, "default poll interval")
			}
		case "candidate":
			if len(parts) != 5 {
				err = errors.New("candidate requires four fields")
				break
			}
			if len(req.Candidates) >= MaxCandidates {
				err = fmt.Errorf("candidate count exceeds %d", MaxCandidates)
				break
			}
			if !validToken(parts[1], 64) || handles[parts[1]] {
				err = errors.New("invalid or duplicate candidate handle")
				break
			}
			if !oneOf(parts[2], "codex", "process", "activity") {
				err = errors.New("invalid candidate kind")
				break
			}
			var title, detail string
			title, err = decodeText(parts[3])
			if err == nil {
				detail, err = decodeText(parts[4])
			}
			if err == nil {
				handles[parts[1]] = true
				req.Candidates = append(req.Candidates, Candidate{
					Handle: parts[1], Kind: parts[2], Title: title, Detail: detail,
				})
			}
		case "end":
			if len(parts) != 1 || seen[key] {
				err = errors.New("invalid or duplicate end marker")
			} else {
				seen[key] = true
				ended = true
			}
		default:
			err = fmt.Errorf("unknown field %q", key)
		}
		if err != nil {
			return Request{}, lineError(line, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return Request{}, fmt.Errorf("scan menu request: %w", err)
	}
	for _, required := range []string{"generation", "system", "power", "defaults", "end"} {
		if !seen[required] {
			return Request{}, fmt.Errorf("missing %s field", required)
		}
	}
	return req, nil
}

func WriteChoice(writer io.Writer, choice Choice) error {
	if err := choice.Validate(); err != nil {
		return err
	}
	var out strings.Builder
	fmt.Fprintf(&out, "%s\ngeneration|%d\naction|%s\n", ResponseHeader, choice.Generation, choice.Action)
	if choice.Action == "start" {
		fmt.Fprintf(&out, "completion|%s\n", choice.Completion)
		for _, handle := range choice.Targets {
			fmt.Fprintf(&out, "target|%s\n", handle)
		}
		fmt.Fprintf(&out, "timeout-seconds|%d\nmin-battery|%d\n", choice.TimeoutSeconds, choice.MinBattery)
	}
	out.WriteString("end\n")
	if out.Len() > MaxResponseSize {
		return errors.New("menu response exceeds 64 KiB")
	}
	_, err := io.WriteString(writer, out.String())
	return err
}

func (choice Choice) Validate() error {
	if choice.Generation != 1 {
		return errors.New("invalid choice generation")
	}
	if !oneOf(choice.Action, "start", "status", "stop", "detect", "doctor", "config", "update", "help", "quit", "cancel") {
		return errors.New("invalid menu action")
	}
	if choice.Action != "start" {
		if choice.Completion != "" || len(choice.Targets) != 0 || choice.TimeoutSeconds != 0 || choice.MinBattery != 0 {
			return errors.New("non-start action contains start fields")
		}
		return nil
	}
	if !oneOf(choice.Completion, "current-all", "current-selected", "manual", "timer", "process-selected") {
		return errors.New("invalid completion mode")
	}
	if choice.TimeoutSeconds < 0 || choice.TimeoutSeconds > 31536000 {
		return errors.New("invalid timeout")
	}
	if choice.MinBattery < 0 || choice.MinBattery > 100 {
		return errors.New("invalid battery floor")
	}
	if choice.Completion == "timer" && choice.TimeoutSeconds == 0 {
		return errors.New("timer requires a timeout")
	}
	requiresTargets := choice.Completion == "current-selected" || choice.Completion == "process-selected"
	if requiresTargets != (len(choice.Targets) > 0) {
		return errors.New("completion has an invalid target set")
	}
	seen := map[string]bool{}
	for _, handle := range choice.Targets {
		if !validToken(handle, 64) || seen[handle] {
			return errors.New("invalid or duplicate target handle")
		}
		seen[handle] = true
	}
	return nil
}

func uniqueScalar(seen map[string]bool, key string, fields []string, wanted int) error {
	if len(fields) != wanted {
		return fmt.Errorf("%s has the wrong field count", key)
	}
	if seen[key] {
		return fmt.Errorf("duplicate %s field", key)
	}
	seen[key] = true
	return nil
}

func parseInt(value string, minimum, maximum int, label string) (int, error) {
	if value == "" || (len(value) > 1 && value[0] == '0') {
		return 0, fmt.Errorf("invalid %s", label)
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("invalid %s", label)
		}
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < minimum || n > maximum {
		return 0, fmt.Errorf("invalid %s", label)
	}
	return n, nil
}

func decodeText(value string) (string, error) {
	decoded, err := base64.StdEncoding.Strict().DecodeString(value)
	if err != nil || len(decoded) > 4096 {
		return "", errors.New("invalid candidate text")
	}
	return textutil.Sanitize(string(decoded)), nil
}

func validToken(value string, maximum int) bool {
	if value == "" || len(value) > maximum {
		return false
	}
	for _, r := range value {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

func oneOf(value string, choices ...string) bool {
	for _, choice := range choices {
		if value == choice {
			return true
		}
	}
	return false
}

func lineError(line int, err error) error {
	return fmt.Errorf("line %d: %w", line, err)
}
