package sshconfig

import (
	"strings"
	"testing"
)

func TestResolvePortLocalhost(t *testing.T) {
	port, err := ResolvePort("localhost")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if port != 22 {
		t.Fatalf("expected port 22 for localhost, got %d", port)
	}
}

func TestResolvePortEmptyHost(t *testing.T) {
	port, err := ResolvePort("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if port != 22 {
		t.Fatalf("expected fallback port 22, got %d", port)
	}
}

func TestParsePort(t *testing.T) {
	output := "host example\nhostname example.com\nport 2222\nuser foo\n"
	var found int
	var foundErr error
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, "port ") {
			found, foundErr = parsePortLine(line)
			break
		}
	}
	if foundErr != nil {
		t.Fatalf("unexpected error: %v", foundErr)
	}
	if found != 2222 {
		t.Fatalf("expected port 2222, got %d", found)
	}
}
