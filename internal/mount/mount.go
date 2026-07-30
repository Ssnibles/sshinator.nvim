package mount

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type PasswordRequiredError struct {
	Name string
}

func (e *PasswordRequiredError) Error() string {
	return fmt.Sprintf("connection %q requires password authentication", e.Name)
}

func IsPasswordRequired(err error) bool {
	_, ok := err.(*PasswordRequiredError)
	return ok
}

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

	if _, err := os.Lstat(dir); err == nil || !os.IsNotExist(err) {
		// Unmount any stale mount via syscall.
		syscall.Unmount(dir, syscall.MNT_DETACH)
		syscall.Unmount(dir, 0)
		if isMounted(dir) {
			return "", fmt.Errorf("stale mount at %s could not be cleaned up; run: sudo umount -l %s", dir, dir)
		}
		if err := os.RemoveAll(dir); err != nil {
			return "", fmt.Errorf("failed to remove existing mount dir: %w", err)
		}
	}

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

	sanitizedName := SanitizeName(name)
	if mountPoint, ok := ms.mounts[name]; ok {
		return mountPoint, nil
	}

	mountPoint, err := MountDir(sanitizedName)
	if err != nil {
		return "", err
	}

	// Ensure mount point has correct permissions
	if err := os.Chmod(mountPoint, 0755); err != nil {
		return "", fmt.Errorf("failed to set mount point permissions: %w", err)
	}

	// Normalize remote path - remove trailing slashes unless it's just "/"
	if remotePath != "/" && len(remotePath) > 1 {
		remotePath = strings.TrimRight(remotePath, "/")
	}

	remote := fmt.Sprintf("%s@%s:%s", user, host, remotePath)

	controlPath := fmt.Sprintf("/tmp/sshinator-%%r@%%h:%d", port)

	args := []string{
		remote,
		mountPoint,
		"-p", fmt.Sprintf("%d", port),
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=3",
		"-o", "reconnect",
		"-o", "follow_symlinks",
		"-o", "ConnectTimeout=10",
		"-o", "ControlMaster=auto",
		"-o", fmt.Sprintf("ControlPath=%s", controlPath),
	}

	if identityFile != "" {
		args = append(args, "-o", fmt.Sprintf("IdentityFile=%s", identityFile))
	}

	var cmd *exec.Cmd
	if password != "" {
		passwordScript := filepath.Join(os.TempDir(), "sshinator-askpass-"+sanitizedName)
		scriptContent := "#!/bin/sh\necho '" + strings.ReplaceAll(password, "'", "'\\''") + "'"
		if err := os.WriteFile(passwordScript, []byte(scriptContent), 0700); err != nil {
			return "", fmt.Errorf("failed to create ssh askpass script: %w", err)
		}
		defer os.Remove(passwordScript)

		cmd = exec.Command("sshfs", args...)
		env := os.Environ()
		env = filterEnv(filterEnv(env, "SSH_ASKPASS"), "SSH_ASKPASS_REQUIRE")
		env = append(env, "SSH_ASKPASS="+passwordScript)
		cmd.Env = env
	} else {
		args = append(args, "-o", "BatchMode=yes")
		cmd = exec.Command("sshfs", args...)
		cmd.Env = filterEnv(filterEnv(os.Environ(), "SSH_ASKPASS"), "SSH_ASKPASS_REQUIRE")
	}

	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("failed to start sshfs: %w", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	select {
	case err := <-done:
		outputStr := stderrBuf.String()
		if err != nil {
			if password == "" && isPasswordError(outputStr, err) {
				return "", &PasswordRequiredError{Name: name}
			}
			return "", fmt.Errorf("sshfs failed: %w\nOutput: %s", err, outputStr)
		}
	case <-time.After(5 * time.Second):
	}

	time.Sleep(200 * time.Millisecond)
	if !isMounted(mountPoint) {
		return "", fmt.Errorf("sshfs did not mount the filesystem")
	}

	ms.mounts[name] = mountPoint
	return mountPoint, nil
}

func isMounted(mountPoint string) bool {
	cmd := exec.Command("mountpoint", "-q", mountPoint)
	return cmd.Run() == nil
}

func isPasswordError(output string, err error) bool {
	outputLower := strings.ToLower(output)
	var errLower string
	if err != nil {
		errLower = strings.ToLower(err.Error())
	}

	passwordIndicators := []string{
		"permission denied",
		"password",
		"authentication failed",
		"publickey",
		"keyboard-interactive",
	}
	
	for _, indicator := range passwordIndicators {
		if strings.Contains(outputLower, indicator) || strings.Contains(errLower, indicator) {
			return true
		}
	}
	return false
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

func HasSshpass() bool {
	_, err := exec.LookPath("sshpass")
	return err == nil
}

func TestConnection(host string, port int, user, identityFile, password string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	args := []string{
		"-p", fmt.Sprintf("%d", port),
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
		"-o", "BatchMode=yes",
		fmt.Sprintf("%s@%s", user, host),
		"exit",
	}

	var cmd *exec.Cmd
	if password != "" {
		if sshpassPath, err := exec.LookPath("sshpass"); err == nil {
			sshpassArgs := []string{"-p", password, "ssh"}
			sshpassArgs = append(sshpassArgs, args...)
			cmd = exec.CommandContext(ctx, sshpassPath, sshpassArgs...)
		} else {
			return fmt.Errorf("password authentication requires sshpass")
		}
	} else {
		if identityFile != "" {
			args = append([]string{"-i", identityFile}, args...)
		}
		cmd = exec.CommandContext(ctx, "ssh", args...)
	}

	cmd.Env = filterEnv(filterEnv(os.Environ(), "SSH_ASKPASS"), "SSH_ASKPASS_REQUIRE")

	output, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("connection timed out after 15 seconds")
		}
		return fmt.Errorf("connection failed: %s", string(output))
	}

	return nil
}

func (ms *MountState) StatusString(name string) string {
	ms.mu.RLock()
	defer ms.mu.RUnlock()
	if mp, ok := ms.mounts[name]; ok {
		return fmt.Sprintf("mounted at %s", mp)
	}
	return "not mounted"
}

func filterEnv(env []string, excludeKey string) []string {
	var filtered []string
	for _, e := range env {
		if !strings.HasPrefix(e, excludeKey+"=") {
			filtered = append(filtered, e)
		}
	}
	return filtered
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
