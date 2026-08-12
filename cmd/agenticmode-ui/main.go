package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"

	tea "charm.land/bubbletea/v2"

	"github.com/ariakalantari/agenticmode/internal/protocol"
	"github.com/ariakalantari/agenticmode/internal/ui"
)

const version = "1.4.1"

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "agenticmode-ui: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string, stdout io.Writer) error {
	if len(args) == 1 {
		switch args[0] {
		case "--version":
			_, err := fmt.Fprintf(stdout, "agenticmode-ui %s\n", version)
			return err
		case "--protocol-version":
			_, err := io.WriteString(stdout, "1\n")
			return err
		}
	}
	if len(args) == 3 && args[0] == "menu" {
		return runMenu(args[1], args[2])
	}
	if len(args) == 4 && args[0] == "render" {
		width, err := parseDimension(args[2])
		if err != nil {
			return err
		}
		height, err := parseDimension(args[3])
		if err != nil {
			return err
		}
		request, err := readRequest(args[1])
		if err != nil {
			return err
		}
		model := ui.NewModel(request)
		model, _ = resizeModel(model, width, height)
		_, err = io.WriteString(stdout, model.Render())
		return err
	}
	return errors.New("usage: agenticmode-ui menu REQUEST_PATH RESPONSE_PATH")
}

func runMenu(requestPath, responsePath string) error {
	request, err := readRequest(requestPath)
	if err != nil {
		return err
	}
	if err := validateResponseDestination(responsePath); err != nil {
		return err
	}

	input, output, err := tea.OpenTTY()
	if err != nil {
		return fmt.Errorf("open controlling terminal: %w", err)
	}
	defer input.Close()
	defer output.Close()

	initial := ui.NewModel(request)
	program := tea.NewProgram(initial, tea.WithInput(input), tea.WithOutput(output), tea.WithFPS(6))
	final, runErr := program.Run()
	if errors.Is(runErr, tea.ErrInterrupted) {
		return writeResponse(responsePath, protocol.Choice{Generation: request.Generation, Action: "cancel"})
	}
	if runErr != nil {
		return fmt.Errorf("run terminal launcher: %w", runErr)
	}
	model, ok := final.(ui.Model)
	if !ok {
		return errors.New("launcher returned an invalid model")
	}
	choice, selected := model.Choice()
	if !selected {
		return errors.New("terminal launcher exited without a choice")
	}
	return writeResponse(responsePath, choice)
}

func resizeModel(model ui.Model, width, height int) (ui.Model, tea.Cmd) {
	updated, command := model.Update(tea.WindowSizeMsg{Width: width, Height: height})
	return updated.(ui.Model), command
}

func parseDimension(value string) (int, error) {
	dimension, err := strconv.Atoi(value)
	if err != nil || dimension < 1 || dimension > 10000 {
		return 0, fmt.Errorf("invalid render dimension %q", value)
	}
	return dimension, nil
}

func readRequest(path string) (protocol.Request, error) {
	file, err := openOwnerOnlyRegular(path)
	if err != nil {
		return protocol.Request{}, fmt.Errorf("open request: %w", err)
	}
	defer file.Close()
	request, err := protocol.ParseRequest(file)
	if err != nil {
		return protocol.Request{}, fmt.Errorf("parse request: %w", err)
	}
	return request, nil
}

func openOwnerOnlyRegular(path string) (*os.File, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("path is not a regular non-symlink file")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("file must not be accessible by group or others")
	}
	if err := ownedByCurrentUser(info); err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	opened, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	if !os.SameFile(info, opened) || !opened.Mode().IsRegular() {
		file.Close()
		return nil, errors.New("request file changed while opening")
	}
	if opened.Mode().Perm()&0o077 != 0 {
		file.Close()
		return nil, errors.New("file must not be accessible by group or others")
	}
	if err := ownedByCurrentUser(opened); err != nil {
		file.Close()
		return nil, err
	}
	return file, nil
}

func validateResponseDestination(path string) error {
	if _, err := os.Lstat(path); err == nil {
		return errors.New("response path already exists")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	parent := filepath.Dir(path)
	info, err := os.Lstat(parent)
	if err != nil {
		return fmt.Errorf("inspect response directory: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("response directory is unsafe")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return errors.New("response directory must not be accessible by group or others")
	}
	return ownedByCurrentUser(info)
}

func writeResponse(path string, choice protocol.Choice) error {
	if err := validateResponseDestination(path); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp.*")
	if err != nil {
		return fmt.Errorf("create temporary response: %w", err)
	}
	temporary := file.Name()
	keepTemporary := true
	defer func() {
		file.Close()
		if keepTemporary {
			_ = os.Remove(temporary)
		}
	}()
	if err := protocol.WriteChoice(file, choice); err != nil {
		return fmt.Errorf("write response: %w", err)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("sync response: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close response: %w", err)
	}
	// Link provides a no-overwrite atomic publication on the same filesystem.
	if err := os.Link(temporary, path); err != nil {
		return fmt.Errorf("publish response: %w", err)
	}
	if err := os.Remove(temporary); err == nil {
		keepTemporary = false
	}
	return nil
}

func ownedByCurrentUser(info os.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return errors.New("path must be owned by the current user")
	}
	return nil
}
