package config

import (
	"os"
	"path/filepath"
	"testing"
)

func setupTestConfig(t *testing.T) func() {
	t.Helper()
	tmpDir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmpDir)
	return func() {}
}

func TestAddAndGet(t *testing.T) {
	setupTestConfig(t)
	cfg := &Config{Connections: []Connection{}}

	conn := Connection{
		Name: "test",
		Host: "example.com",
		Port: 2222,
		User: "user",
	}
	if err := cfg.Add(conn); err != nil {
		t.Fatalf("Add failed: %v", err)
	}

	got, err := cfg.Get("test")
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if got.Host != "example.com" || got.Port != 2222 {
		t.Fatalf("unexpected connection: %+v", got)
	}
}

func TestAddDuplicate(t *testing.T) {
	setupTestConfig(t)
	cfg := &Config{Connections: []Connection{}}

	conn := Connection{Name: "test", Host: "example.com", User: "user"}
	if err := cfg.Add(conn); err != nil {
		t.Fatalf("Add failed: %v", err)
	}

	if err := cfg.Add(conn); err == nil {
		t.Fatal("expected duplicate error")
	}
}

func TestAddDefaults(t *testing.T) {
	setupTestConfig(t)
	cfg := &Config{Connections: []Connection{}}

	conn := Connection{Name: "test", Host: "example.com", User: "user"}
	if err := cfg.Add(conn); err != nil {
		t.Fatalf("Add failed: %v", err)
	}

	got, _ := cfg.Get("test")
	if got.Port != 22 {
		t.Fatalf("expected default port 22, got %d", got.Port)
	}
	if got.RemotePath != "." {
		t.Fatalf("expected default remote path '.', got %q", got.RemotePath)
	}
}

func TestRemove(t *testing.T) {
	setupTestConfig(t)
	cfg := &Config{Connections: []Connection{}}

	cfg.Add(Connection{Name: "a", Host: "a.com", User: "user"})
	cfg.Add(Connection{Name: "b", Host: "b.com", User: "user"})

	if err := cfg.Remove("a"); err != nil {
		t.Fatalf("Remove failed: %v", err)
	}

	if _, err := cfg.Get("a"); err == nil {
		t.Fatal("expected not found error")
	}
	if _, err := cfg.Get("b"); err != nil {
		t.Fatalf("Get b failed: %v", err)
	}
}

func TestUpdate(t *testing.T) {
	setupTestConfig(t)
	cfg := &Config{Connections: []Connection{}}

	cfg.Add(Connection{Name: "test", Host: "old.com", User: "user"})
	cfg.Update("test", Connection{Name: "ignored", Host: "new.com", User: "user"})

	got, _ := cfg.Get("test")
	if got.Host != "new.com" {
		t.Fatalf("expected host new.com, got %s", got.Host)
	}
}

func TestLoadAndSave(t *testing.T) {
	setupTestConfig(t)

	cfg := &Config{Connections: []Connection{
		{Name: "test", Host: "example.com", Port: 22, User: "user"},
	}}
	if err := Save(cfg); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	loaded, err := Load()
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}
	if len(loaded.Connections) != 1 {
		t.Fatalf("expected 1 connection, got %d", len(loaded.Connections))
	}
	if loaded.Connections[0].Name != "test" {
		t.Fatalf("unexpected connection name: %s", loaded.Connections[0].Name)
	}
}

func TestConfigPath(t *testing.T) {
	setupTestConfig(t)

	path, err := ConfigPath()
	if err != nil {
		t.Fatalf("ConfigPath failed: %v", err)
	}

	expected := filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "sshinator", "connections.json")
	if path != expected {
		t.Fatalf("expected path %s, got %s", expected, path)
	}
}
