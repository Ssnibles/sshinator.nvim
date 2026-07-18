package rpc

import (
	"io"
	"log"
	"testing"
)

func newTestServer() *Server {
	return &Server{
		reader: nil,
		writer: io.Discard,
		logger: log.New(io.Discard, "[test] ", log.LstdFlags),
		mounts: nil,
	}
}

func TestResolvePortPreservesExplicit(t *testing.T) {
	s := newTestServer()
	port := s.resolvePort("localhost", 2222)
	if port != 2222 {
		t.Fatalf("expected explicit port 2222 to be preserved, got %d", port)
	}
}

func TestResolvePortDefault(t *testing.T) {
	s := newTestServer()
	port := s.resolvePort("localhost", 22)
	if port != 22 {
		t.Fatalf("expected localhost to resolve to 22, got %d", port)
	}
}

func TestResolvePortZero(t *testing.T) {
	s := newTestServer()
	port := s.resolvePort("localhost", 0)
	if port != 22 {
		t.Fatalf("expected port 0 to resolve to 22 for localhost, got %d", port)
	}
}
