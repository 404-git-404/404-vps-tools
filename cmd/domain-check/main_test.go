package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func TestColorSelection(t *testing.T) {
	if !colorEnabled(os.ModeCharDevice, false) {
		t.Fatal("TTY output should enable color")
	}
	if colorEnabled(0, false) {
		t.Fatal("non-TTY output should disable color")
	}
	if colorEnabled(os.ModeCharDevice, true) {
		t.Fatal("NO_COLOR should disable color")
	}
}

func TestVersion(t *testing.T) {
	originalVersion, originalCommit, originalBuildDate := version, commit, buildDate
	version, commit, buildDate = "v2.0.0", "0123456789abcdef", "2026-08-14T00:00:00Z"
	t.Cleanup(func() {
		version, commit, buildDate = originalVersion, originalCommit, originalBuildDate
	})
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	if status := run([]string{"--version"}, &stdout, &stderr, false); status != 0 {
		t.Fatalf("--version status = %d", status)
	}
	want := "domain-check Go v2.0.0 (commit 0123456789abcdef, built 2026-08-14T00:00:00Z)\n"
	if stdout.String() != want {
		t.Fatalf("--version output = %q, want %q", stdout.String(), want)
	}
	if stderr.Len() != 0 {
		t.Fatalf("--version stderr = %q", stderr.String())
	}
	if strings.Contains(stdout.String(), "domain-check.sh") {
		t.Fatal("--version did not identify the Go implementation")
	}
}
