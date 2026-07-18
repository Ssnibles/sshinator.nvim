package mount

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPasswordRequiredError(t *testing.T) {
	err := &PasswordRequiredError{Name: "test"}
	if err.Error() != `connection "test" requires password authentication` {
		t.Fatalf("unexpected error message: %s", err.Error())
	}
	if !IsPasswordRequired(err) {
		t.Fatal("expected IsPasswordRequired to be true")
	}
	if IsPasswordRequired(nil) {
		t.Fatal("expected IsPasswordRequired(nil) to be false")
	}
}

func TestSanitizeName(t *testing.T) {
	cases := map[string]string{
		"my server":  "my_server",
		"a/b":        "a_b",
		"a\\b":       "a_b",
		"a:b":        "a_b",
		"plain-name": "plain-name",
	}
	for input, expected := range cases {
		if got := SanitizeName(input); got != expected {
			t.Fatalf("SanitizeName(%q) = %q, want %q", input, got, expected)
		}
	}
}

func TestMountDir(t *testing.T) {
	tmpDir := t.TempDir()
	t.Setenv("XDG_DATA_HOME", tmpDir)

	dir, err := MountDir("my-server")
	if err != nil {
		t.Fatalf("MountDir failed: %v", err)
	}

	expected := filepath.Join(tmpDir, "sshinator", "mounts", "my-server")
	if dir != expected {
		t.Fatalf("expected %s, got %s", expected, dir)
	}

	info, err := os.Stat(dir)
	if err != nil {
		t.Fatalf("stat failed: %v", err)
	}
	if !info.IsDir() {
		t.Fatal("expected directory")
	}
}

func TestMountState(t *testing.T) {
	ms := NewMountState()

	if ms.IsMounted("foo") {
		t.Fatal("expected foo to not be mounted")
	}

	ms.mounts["foo"] = "/tmp/foo"
	if !ms.IsMounted("foo") {
		t.Fatal("expected foo to be mounted")
	}

	mp, ok := ms.GetMountPoint("foo")
	if !ok || mp != "/tmp/foo" {
		t.Fatalf("unexpected mount point: %s", mp)
	}

	mounted := ms.ListMounted()
	if len(mounted) != 1 || mounted[0] != "foo" {
		t.Fatalf("unexpected mounted list: %v", mounted)
	}

	info := ms.MountInfo()
	if info["foo"] != "/tmp/foo" {
		t.Fatalf("unexpected mount info: %v", info)
	}
}

func TestStatusString(t *testing.T) {
	ms := NewMountState()
	if ms.StatusString("foo") != "not mounted" {
		t.Fatal("expected not mounted status")
	}
	ms.mounts["foo"] = "/tmp/foo"
	if ms.StatusString("foo") != "mounted at /tmp/foo" {
		t.Fatalf("unexpected status: %s", ms.StatusString("foo"))
	}
}

func TestCheckDependencies(t *testing.T) {
	missing := CheckDependencies()
	// We cannot assert exact contents without controlling PATH, but we can
	// verify the result is a slice (nil or non-nil is acceptable).
	if missing == nil {
		return
	}
	for _, dep := range missing {
		if dep != "sshfs" && dep != "fusermount" {
			t.Fatalf("unexpected dependency: %s", dep)
		}
	}
}

func TestHasSshpass(t *testing.T) {
	// Just verify it does not panic and returns a bool.
	_ = HasSshpass()
}

func TestIsPasswordError(t *testing.T) {
	if !isPasswordError("Permission denied", nil) {
		t.Fatal("expected permission denied to match")
	}
	if !isPasswordError("", &PasswordRequiredError{Name: "x"}) {
		t.Fatal("expected password required error to match")
	}
	if isPasswordError("some random output", nil) {
		t.Fatal("expected random output to not match")
	}
}
