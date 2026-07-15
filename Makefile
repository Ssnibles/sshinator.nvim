.PHONY: build clean install

BINARY = bin/sshinator

build:
	@mkdir -p bin
	go build -o $(BINARY) ./cmd/sshinator

clean:
	rm -rf bin/

install: build
	@echo "Binary built at $(BINARY)"
