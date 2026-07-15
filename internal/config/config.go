package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Connection struct {
	Name       string `json:"name"`
	Host       string `json:"host"`
	Port       int    `json:"port"`
	User       string `json:"user"`
	IdentityFile string `json:"identity_file,omitempty"`
	RemotePath string `json:"remote_path,omitempty"`
}

type Config struct {
	Connections []Connection `json:"connections"`
}

func ConfigPath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("failed to get config dir: %w", err)
	}
	return filepath.Join(configDir, "sshinator", "connections.json"), nil
}

func Load() (*Config, error) {
	path, err := ConfigPath()
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Config{Connections: []Connection{}}, nil
		}
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}
	return &cfg, nil
}

func Save(cfg *Config) error {
	path, err := ConfigPath()
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return fmt.Errorf("failed to create config dir: %w", err)
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	return os.WriteFile(path, data, 0644)
}

func (c *Config) Add(conn Connection) error {
	for _, existing := range c.Connections {
		if existing.Name == conn.Name {
			return fmt.Errorf("connection %q already exists", conn.Name)
		}
	}
	if conn.Port == 0 {
		conn.Port = 22
	}
	if conn.RemotePath == "" {
		conn.RemotePath = "."
	}
	c.Connections = append(c.Connections, conn)
	return nil
}

func (c *Config) Remove(name string) error {
	for i, conn := range c.Connections {
		if conn.Name == name {
			c.Connections = append(c.Connections[:i], c.Connections[i+1:]...)
			return nil
		}
	}
	return fmt.Errorf("connection %q not found", name)
}

func (c *Config) Get(name string) (*Connection, error) {
	for i := range c.Connections {
		if c.Connections[i].Name == name {
			return &c.Connections[i], nil
		}
	}
	return nil, fmt.Errorf("connection %q not found", name)
}

func (c *Config) Update(name string, updated Connection) error {
	for i := range c.Connections {
		if c.Connections[i].Name == name {
			updated.Name = name
			c.Connections[i] = updated
			return nil
		}
	}
	return fmt.Errorf("connection %q not found", name)
}
