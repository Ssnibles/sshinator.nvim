package rpc

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"sync"

	"github.com/josh/sshinator.nvim/internal/config"
	"github.com/josh/sshinator.nvim/internal/mount"
)

type Request struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type Response struct {
	ID     int         `json:"id"`
	Result interface{} `json:"result,omitempty"`
	Error  string      `json:"error,omitempty"`
}

type Server struct {
	mu     sync.Mutex
	reader *bufio.Reader
	writer io.Writer
	logger *log.Logger
	mounts *mount.MountState
}

func NewServer() *Server {
	logFile, err := os.OpenFile("/tmp/sshinator.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	var logWriter io.Writer = io.Discard
	if err == nil {
		logWriter = logFile
	}
	return &Server{
		reader: bufio.NewReader(os.Stdin),
		writer: os.Stdout,
		logger: log.New(logWriter, "[sshinator] ", log.LstdFlags),
		mounts: mount.NewMountState(),
	}
}

func (s *Server) sendResponse(resp Response) {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, _ := json.Marshal(resp)
	fmt.Fprintln(s.writer, string(data))
}

func (s *Server) Run() {
	s.logger.Println("server started")
	for {
		line, err := s.reader.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				s.logger.Println("stdin closed, shutting down")
				s.mounts.UnmountAll()
				return
			}
			s.logger.Printf("read error: %v", err)
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			s.sendResponse(Response{Error: fmt.Sprintf("invalid request: %v", err)})
			continue
		}

		s.logger.Printf("request: id=%d method=%s", req.ID, req.Method)
		go func(req Request) {
			result, err := s.handleRequest(req)
			resp := Response{ID: req.ID}
			if err != nil {
				resp.Error = err.Error()
				s.logger.Printf("error: %v", err)
			} else {
				resp.Result = result
			}
			s.sendResponse(resp)
		}(req)
	}
}

func (s *Server) handleRequest(req Request) (interface{}, error) {
	switch req.Method {
	case "list_connections":
		return s.listConnections()
	case "add_connection":
		return s.addConnection(req.Params)
	case "remove_connection":
		return s.removeConnection(req.Params)
	case "get_connection":
		return s.getConnection(req.Params)
	case "update_connection":
		return s.updateConnection(req.Params)
	case "connect":
		return s.connect(req.Params)
	case "connect_with_password":
		return s.connectWithPassword(req.Params)
	case "disconnect":
		return s.disconnect(req.Params)
	case "status":
		return s.status(req.Params)
	case "list_mounted":
		return s.listMounted()
	case "check_deps":
		return s.checkDeps()
	case "disconnect_all":
		return s.disconnectAll()
	case "test_connection":
		return s.testConnection(req.Params)
	case "sudo_write":
		return s.sudoWrite(req.Params)
	default:
		return nil, fmt.Errorf("unknown method: %s", req.Method)
	}
}

func (s *Server) listConnections() (interface{}, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	return cfg.Connections, nil
}

type nameParam struct {
	Name string `json:"name"`
}

func (s *Server) addConnection(params json.RawMessage) (interface{}, error) {
	var conn config.Connection
	if err := json.Unmarshal(params, &conn); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}

	if err := cfg.Add(conn); err != nil {
		return nil, err
	}

	if err := config.Save(cfg); err != nil {
		return nil, err
	}

	return map[string]string{"status": "added", "name": conn.Name}, nil
}

func (s *Server) removeConnection(params json.RawMessage) (interface{}, error) {
	var p nameParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	if s.mounts.IsMounted(p.Name) {
		if err := s.mounts.Unmount(p.Name); err != nil {
			return nil, fmt.Errorf("failed to unmount: %w", err)
		}
	}

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}

	if err := cfg.Remove(p.Name); err != nil {
		return nil, err
	}

	return map[string]string{"status": "removed", "name": p.Name}, config.Save(cfg)
}

func (s *Server) getConnection(params json.RawMessage) (interface{}, error) {
	var p nameParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}

	return cfg.Get(p.Name)
}

type updateParam struct {
	Name    string           `json:"name"`
	Updated config.Connection `json:"updated"`
}

func (s *Server) updateConnection(params json.RawMessage) (interface{}, error) {
	var p updateParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}

	if err := cfg.Update(p.Name, p.Updated); err != nil {
		return nil, err
	}

	return map[string]string{"status": "updated", "name": p.Name}, config.Save(cfg)
}

func (s *Server) connect(params json.RawMessage) (interface{}, error) {
	var p nameParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}

	conn, err := cfg.Get(p.Name)
	if err != nil {
		return nil, err
	}

	if conn.PasswordAuth {
		return map[string]interface{}{
			"needs_password": true,
			"name":           conn.Name,
		}, nil
	}

	mountPoint, err := s.mounts.Mount(
		conn.Name,
		conn.Host,
		conn.Port,
		conn.User,
		conn.IdentityFile,
		conn.RemotePath,
	)
	if err != nil {
		if mount.IsPasswordRequired(err) {
			return map[string]interface{}{
				"needs_password": true,
				"name":           conn.Name,
			}, nil
		}
		return nil, err
	}

	return map[string]string{
		"status":      "connected",
		"name":        conn.Name,
		"mount_point": mountPoint,
	}, nil
}

type connectPasswordParam struct {
	Name     string `json:"name"`
	Password string `json:"password"`
}

func (s *Server) connectWithPassword(params json.RawMessage) (interface{}, error) {
	var p connectPasswordParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}

	conn, err := cfg.Get(p.Name)
	if err != nil {
		return nil, err
	}

	mountPoint, err := s.mounts.MountWithPassword(
		conn.Name,
		conn.Host,
		conn.Port,
		conn.User,
		conn.RemotePath,
		p.Password,
	)
	if err != nil {
		return nil, err
	}

	return map[string]string{
		"status":      "connected",
		"name":        conn.Name,
		"mount_point": mountPoint,
	}, nil
}

func (s *Server) disconnect(params json.RawMessage) (interface{}, error) {
	var p nameParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	if err := s.mounts.Unmount(p.Name); err != nil {
		return nil, err
	}

	return map[string]string{"status": "disconnected", "name": p.Name}, nil
}

func (s *Server) status(params json.RawMessage) (interface{}, error) {
	var p nameParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	mounted := s.mounts.IsMounted(p.Name)
	mountPoint := ""
	if mounted {
		mp, _ := s.mounts.GetMountPoint(p.Name)
		mountPoint = mp
	}

	return map[string]interface{}{
		"name":        p.Name,
		"mounted":     mounted,
		"mount_point": mountPoint,
	}, nil
}

func (s *Server) listMounted() (interface{}, error) {
	return s.mounts.MountInfo(), nil
}

func (s *Server) checkDeps() (interface{}, error) {
	missing := mount.CheckDependencies()
	return map[string]interface{}{
		"ok":      len(missing) == 0,
		"missing": missing,
	}, nil
}

func (s *Server) disconnectAll() (interface{}, error) {
	s.mounts.UnmountAll()
	return map[string]string{"status": "all disconnected"}, nil
}

type testConnectionParam struct {
	Host         string `json:"host"`
	Port         int    `json:"port"`
	User         string `json:"user"`
	IdentityFile string `json:"identity_file,omitempty"`
	Password     string `json:"password,omitempty"`
}

func (s *Server) testConnection(params json.RawMessage) (interface{}, error) {
	var p testConnectionParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	if p.Port == 0 {
		p.Port = 22
	}

	err := mount.TestConnection(p.Host, p.Port, p.User, p.IdentityFile, p.Password)
	if err != nil {
		return map[string]interface{}{
			"success": false,
			"error":   err.Error(),
		}, nil
	}

	return map[string]interface{}{
		"success": true,
	}, nil
}

type sudoWriteParam struct {
	Name       string `json:"name"`
	LocalFile  string `json:"local_file"`
	RemotePath string `json:"remote_path"`
	Password   string `json:"password"`
}

func (s *Server) sudoWrite(params json.RawMessage) (interface{}, error) {
	var p sudoWriteParam
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, fmt.Errorf("invalid params: %w", err)
	}

	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}

	conn, err := cfg.Get(p.Name)
	if err != nil {
		return nil, err
	}

	err = mount.SudoWrite(conn.Host, conn.Port, conn.User, p.LocalFile, p.RemotePath, p.Password)
	if err != nil {
		return map[string]interface{}{
			"success": false,
			"error":   err.Error(),
		}, nil
	}

	return map[string]interface{}{
		"success": true,
	}, nil
}
