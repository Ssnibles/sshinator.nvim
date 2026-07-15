package mount

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

type MountState struct {
	mu     sync.RWMutex
	mounts map[string]string
}

func NewMountState() *MountState {
	return &MountState{
		mounts: make(map[string]string),
	}
}

func MountDir(name string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to get home dir: %w", err)
	}
	dataDir := os.Getenv("XDG_DATA_HOME")
	if dataDir == "" {
		dataDir = filepath.Join(home, ".local", "share")
	}
	dir := filepath.Join(dataDir, "sshinator", "mounts", name)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", fmt.Errorf("failed to create mount dir: %w", err)
	}
	return dir, nil
}

func (ms *MountState) Mount(name, host string, port int, user, identityFile, remotePath string) (string, error) {
	return ms.mountInternal(name, host, port, user, identityFile, remotePath, "")
}

func (ms *MountState) MountWithPassword(name, host string, port int, user, remotePath, password string) (string, error) {
	return ms.mountInternal(name, host, port, user, "", remotePath, password)
}

func (ms *MountState) mountInternal(name, host string, port int, user, identityFile, remotePath, password string) (string, error) {
	ms.mu.Lock()
	defer ms.mu.Unlock()

	if mountPoint, ok := ms.mounts[name]; ok {
		return mountPoint, nil
	}

	mountPoint, err := MountDir(name)
	if err != nil {
		return "", err
	}

	remote := fmt.Sprintf("%s@%s:%s", user, host, remotePath)

	args := []string{
		remote,
		mountPoint,
		"-p", fmt.Sprintf("%d", port),
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "reconnect",
		"-o", "follow_symlinks",
	}

	if identityFile != "" {
		args = append(args, "-o", fmt.Sprintf("IdentityFile=%s", identityFile))
	}

	var cmd *exec.Cmd
	if password != "" {
		askpassScript, err := createAskpassScript(password)
		if err != nil {
			return "", fmt.Errorf("failed to create askpass script: %w", err)
		}
		defer os.Remove(askpassScript)

		cmd = exec.Command("sshfs", args...)
		cmd.Env = append(os.Environ(),
			fmt.Sprintf("SSH_ASKPASS=%s", askpassScript),
			fmt.Sprintf("SSH_ASKPASS_REQUIRE=force"),
			"DISPLAY=:0",
		)
	} else {
		cmd = exec.Command("sshfs", args...)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("sshfs failed: %w\nOutput: %s", err, string(output))
	}

	ms.mounts[name] = mountPoint
	return mountPoint, nil
}

func createAskpassScript(password string) (string, error) {
	tmpFile, err := os.CreateTemp("", "sshinator-askpass-*")
	if err != nil {
		return "", err
	}

	script := fmt.Sprintf("#!/bin/sh\necho '%s'\n", strings.ReplaceAll(password, "'", "'\"'\"'"))
	if _, err := tmpFile.WriteString(script); err != nil {
		tmpFile.Close()
		os.Remove(tmpFile.Name())
		return "", err
	}
	tmpFile.Close()

	if err := os.Chmod(tmpFile.Name(), 0700); err != nil {
		os.Remove(tmpFile.Name())
		return "", err
	}

	return tmpFile.Name(), nil
}

func (ms *MountState) Unmount(name string) error {
	ms.mu.Lock()
	defer ms.mu.Unlock()

	mountPoint, ok := ms.mounts[name]
	if !ok {
		return fmt.Errorf("connection %q is not mounted", name)
	}

	cmd := exec.Command("fusermount", "-u", mountPoint)
	output, err := cmd.CombinedOutput()
	if err != nil {
		cmd = exec.Command("umount", mountPoint)
		output, err = cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("unmount failed: %w\nOutput: %s", err, string(output))
		}
	}

	delete(ms.mounts, name)
	return nil
}

func (ms *MountState) UnmountAll() {
	ms.mu.Lock()
	defer ms.mu.Unlock()

	for name, mountPoint := range ms.mounts {
		cmd := exec.Command("fusermount", "-u", mountPoint)
		if err := cmd.Run(); err != nil {
			cmd = exec.Command("umount", mountPoint)
			cmd.Run()
		}
		delete(ms.mounts, name)
	}
}

func (ms *MountState) IsMounted(name string) bool {
	ms.mu.RLock()
	defer ms.mu.RUnlock()
	_, ok := ms.mounts[name]
	return ok
}

func (ms *MountState) GetMountPoint(name string) (string, bool) {
	ms.mu.RLock()
	defer ms.mu.RUnlock()
	mp, ok := ms.mounts[name]
	return mp, ok
}

func (ms *MountState) ListMounted() []string {
	ms.mu.RLock()
	defer ms.mu.RUnlock()
	names := make([]string, 0, len(ms.mounts))
	for name := range ms.mounts {
		names = append(names, name)
	}
	return names
}

func (ms *MountState) MountInfo() map[string]string {
	ms.mu.RLock()
	defer ms.mu.RUnlock()
	info := make(map[string]string, len(ms.mounts))
	for k, v := range ms.mounts {
		info[k] = v
	}
	return info
}

func CheckDependencies() []string {
	var missing []string
	for _, dep := range []string{"sshfs", "fusermount"} {
		if _, err := exec.LookPath(dep); err != nil {
			missing = append(missing, dep)
		}
	}
	return missing
}

func (ms *MountState) StatusString(name string) string {
	ms.mu.RLock()
	defer ms.mu.RUnlock()
	if mp, ok := ms.mounts[name]; ok {
		return fmt.Sprintf("mounted at %s", mp)
	}
	return "not mounted"
}

func SanitizeName(name string) string {
	replacer := strings.NewReplacer(
		" ", "_",
		"/", "_",
		"\\", "_",
		":", "_",
	)
	return replacer.Replace(name)
}
