package sshconfig

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

func parsePortLine(line string) (int, error) {
	portStr := strings.TrimSpace(strings.TrimPrefix(strings.ToLower(line), "port "))
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return 22, fmt.Errorf("invalid port in ssh config: %w", err)
	}
	return port, nil
}

// ResolvePort returns the port ssh would use for the given host by running
// `ssh -G <host>` and parsing the resolved port value. It falls back to 22 if
// the host is empty, ssh is unavailable, or no port is found.
func ResolvePort(host string) (int, error) {
	if host == "" {
		return 22, nil
	}

	out, err := exec.Command("ssh", "-G", host).Output()
	if err != nil {
		return 22, fmt.Errorf("ssh -G failed: %w", err)
	}

	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(strings.ToLower(line), "port ") {
			return parsePortLine(line)
		}
	}

	return 22, nil
}
