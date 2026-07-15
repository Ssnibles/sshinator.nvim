package main

import (
	"github.com/josh/sshinator.nvim/internal/rpc"
)

func main() {
	server := rpc.NewServer()
	server.Run()
}
