SHELL := /bin/bash
DOCKER_DESKTOP_BIN := /Applications/Docker.app/Contents/Resources/bin
export PATH := $(DOCKER_DESKTOP_BIN):$(PATH)
DOCKER := $(shell command -v docker 2>/dev/null || test ! -x $(DOCKER_DESKTOP_BIN)/docker || printf '%s\n' $(DOCKER_DESKTOP_BIN)/docker)
DOCKER_COMPOSE := $(DOCKER) compose
APP_PORT ?= 8080
SCAN_PORT ?= 8081
SOURCE ?= $(CURDIR)/keygenmusic
DOCKER_SOURCE ?= /sources/keygen

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "OrzMusic developer commands"
	@echo ""
	@echo "Setup:"
	@echo "  make setup          Install native and Web OrzAudioCore SDK assets"
	@echo "  make sdk-server     Install native OrzAudioCore SDK"
	@echo "  make sdk-web        Install Web/WASM OrzAudioCore SDK"
	@echo ""
	@echo "Local:"
	@echo "  make status         Show local ports and Docker service status"
	@echo "  make build          Build the Swift service"
	@echo "  make run            Run the Vapor service locally"
	@echo "  make stop           Stop local OrzMusic services and Docker services"
	@echo "  make restart        Stop then run the local Vapor service"
	@echo "  make scan-local     Trigger scan on the local service (SOURCE=/path/to/music)"
	@echo "  make audit-fingerprints Validate production fingerprint policy (ALL=1 for eligible full scan)"
	@echo "  make test           Run Swift and browser tests"
	@echo "  make swift-test     Run Swift tests"
	@echo "  make browser-test   Run browser/WASM tests"
	@echo ""
	@echo "Docker:"
	@echo "  make docker-up      Build and start the full stack in Docker"
	@echo "  make docker-restart Stop then start the full Docker stack"
	@echo "  make docker-down    Stop Docker services"
	@echo "  make docker-logs    Follow app logs"
	@echo "  make docker-config  Validate docker-compose.yml"
	@echo "  make migrate        Run database migrations in Docker"
	@echo "  make scan-docker    Start the scanner service in Docker"
	@echo "  make scan-docker-run Trigger Docker scanner (DOCKER_SOURCE=/sources/keygen)"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean          Remove local Swift build artifacts"

.PHONY: setup
setup: sdk-server sdk-web

.PHONY: sdk-server
sdk-server:
	./script/update-audio-core-server.sh

.PHONY: sdk-web
sdk-web:
	./script/update-audio-core-web.sh

.PHONY: build
build:
	swift build

.PHONY: status
status:
	@echo "Ports:"
	@for port in $(APP_PORT) $(SCAN_PORT); do \
		pids="$$(lsof -tiTCP:$$port -sTCP:LISTEN 2>/dev/null || true)"; \
		if [ -n "$$pids" ]; then \
			echo "  $$port: in use by PID(s) $$pids"; \
			lsof -nP -iTCP:$$port -sTCP:LISTEN 2>/dev/null | sed 's/^/    /'; \
		else \
			echo "  $$port: free"; \
		fi; \
	done
	@echo ""
	@echo "Docker:"
	@if [ -n "$(DOCKER)" ]; then \
		$(DOCKER_COMPOSE) ps; \
	else \
		echo "  docker CLI not found"; \
	fi

.PHONY: stop-local
stop-local:
	@for port in $(APP_PORT) $(SCAN_PORT); do \
		pids="$$(lsof -tiTCP:$$port -sTCP:LISTEN 2>/dev/null || true)"; \
		if [ -z "$$pids" ]; then \
			echo "No local listener on port $$port"; \
			continue; \
		fi; \
		for pid in $$pids; do \
			cmd="$$(ps -p $$pid -o command= 2>/dev/null || true)"; \
			case "$$cmd" in \
				*OrzMusicService*|*".build"*"/Run"*|*"swift run OrzMusicService"*) \
					echo "Stopping local OrzMusic PID $$pid on port $$port"; \
					kill $$pid 2>/dev/null || true; \
					;; \
				*) \
					echo "Port $$port is used by PID $$pid, but it does not look like OrzMusic: $$cmd"; \
					echo "Leaving it running."; \
					;; \
			esac; \
		done; \
	done

.PHONY: stop
stop: stop-local docker-down

.PHONY: run
run:
	swift run OrzMusicService

.PHONY: restart
restart: stop-local run

.PHONY: scan-local
scan-local:
	@echo "Scanning local source through http://127.0.0.1:$(APP_PORT)/api/scan"
	@echo "SOURCE=$(SOURCE)"
	curl -fsS -X POST "http://127.0.0.1:$(APP_PORT)/api/scan" \
		-H "Content-Type: application/json" \
		-d '{"sources":["$(SOURCE)"]}'

.PHONY: audit-fingerprints
audit-fingerprints:
	@args='--source "$(SOURCE)"'; \
	if [ "$(ALL)" = "1" ]; then args="$$args --all"; else args="$$args --limit-per-format \"$${LIMIT_PER_FORMAT:-1}\""; fi; \
	if [ "$(FORCE_ALL_FORMATS)" = "1" ]; then args="$$args --force-all-formats"; fi; \
	if [ -n "$(FORMATS)" ]; then args="$$args --formats \"$(FORMATS)\""; fi; \
	echo "swift run OrzFingerprintAudit $$args"; \
	eval swift run OrzFingerprintAudit "$$args"

.PHONY: test
test: swift-test browser-test docker-config

.PHONY: swift-test
swift-test:
	swift test

.PHONY: browser-test
browser-test:
	node --test Tests/Browser/*.test.mjs

.PHONY: docker-build
docker-build:
	$(DOCKER_COMPOSE) build

.PHONY: docker-up
docker-up:
	$(DOCKER_COMPOSE) up --build -d

.PHONY: docker-restart
docker-restart: docker-down docker-up

.PHONY: docker-down
docker-down:
	$(DOCKER_COMPOSE) down

.PHONY: docker-logs
docker-logs:
	$(DOCKER_COMPOSE) logs -f app

.PHONY: docker-config
docker-config:
	$(DOCKER_COMPOSE) config --quiet

.PHONY: migrate
migrate:
	$(DOCKER_COMPOSE) run --rm migrate

.PHONY: scan-docker
scan-docker:
	$(DOCKER_COMPOSE) run --rm --service-ports scan

.PHONY: scan-docker-run
scan-docker-run:
	@echo "Scanning Docker source through http://127.0.0.1:$(SCAN_PORT)/api/scan"
	@echo "DOCKER_SOURCE=$(DOCKER_SOURCE)"
	curl -fsS -X POST "http://127.0.0.1:$(SCAN_PORT)/api/scan" \
		-H "Content-Type: application/json" \
		-d '{"sources":["$(DOCKER_SOURCE)"]}'

.PHONY: clean
clean:
	swift package clean
