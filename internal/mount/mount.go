package mount

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
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
		"-o", "ConnectTimeout=10",
	}

	if identityFile != "" {
		args = append(args, "-o", fmt.Sprintf("IdentityFile=%s", identityFile))
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var cmd *exec.Cmd
	if password != "" {
		if sshpassPath, err := exec.LookPath("sshpass"); err == nil {
			sshpassArgs := []string{"-p", password, "sshfs"}
			sshpassArgs = append(sshpassArgs, args...)
			cmd = exec.CommandContext(ctx, sshpassPath, sshpassArgs...)
		} else {
			args = append(args, "-o", "password_stdin")
			cmd = exec.CommandContext(ctx, "sshfs", args...)
			cmd.Stdin = strings.NewReader(password + "\n")
		}
	} else {
		cmd = exec.CommandContext(ctx, "sshfs", args...)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return "", fmt.Errorf("sshfs connection timed out after 30 seconds")
		}
		outputStr := string(output)
		if password == "" && isPasswordError(outputStr, err) {
			return "", &PasswordRequiredError{Name: name}
		}
		return "", fmt.Errorf("sshfs failed: %w\nOutput: %s", err, outputStr)
	}

	ms.mounts[name] = mountPoint
	return mountPoint, nil
}

func isPasswordError(output string, err error) bool {
	outputLower := strings.ToLower(output)
	errLower := strings.ToLower(err.Error())
	
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
