#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════
#  Squad Oracle Network — Node Update
#  Pulls latest image and restarts. Config is preserved.
# ═══════════════════════════════════════════════════════

INSTALL_DIR="/opt/son-node"
IMAGE="ghcr.io/squadswapdefi/son-node:latest"
REPO_BASE="https://raw.githubusercontent.com/SquadSwapDeFi/SquadSwapOracleNetwork/main"
COMPOSE_URL="${REPO_BASE}/docker-compose.yml"
CHECKSUMS_URL="${REPO_BASE}/checksums.sha256"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} Please run as root: sudo bash update.sh" >&2
  exit 1
fi

if [ ! -f "$INSTALL_DIR/.env" ]; then
  echo -e "${RED}[ERROR]${NC} No installation found at $INSTALL_DIR. Run setup.sh first." >&2
  exit 1
fi

trap 'rm -f /tmp/son-checksums.sha256' EXIT

echo -e "${CYAN}[INFO]${NC} Updating docker-compose.yml..."
curl -fsSL "$COMPOSE_URL" -o "$INSTALL_DIR/docker-compose.yml"
curl -fsSL "$CHECKSUMS_URL" -o /tmp/son-checksums.sha256
EXPECTED=$(awk '$2 == "docker-compose.yml" {print $1}' /tmp/son-checksums.sha256)
if [ -n "$EXPECTED" ]; then
  ACTUAL=$(sha256sum "$INSTALL_DIR/docker-compose.yml" | awk '{print $1}')
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo -e "${RED}[ERROR]${NC} Checksum mismatch! File may have been tampered with. Aborting." >&2
    rm -f "$INSTALL_DIR/docker-compose.yml"
    exit 1
  fi
  echo -e "${GREEN}[OK]${NC} Checksum verified"
else
  echo -e "${RED}[ERROR]${NC} Checksum entry for docker-compose.yml not found. Aborting." >&2
  rm -f "$INSTALL_DIR/docker-compose.yml"
  exit 1
fi

echo -e "${CYAN}[INFO]${NC} Pulling latest image and restarting..."
cd "$INSTALL_DIR"
docker compose up -d --pull always

sleep 3
if curl -sf http://localhost:9090/health >/dev/null 2>&1; then
  echo -e "${GREEN}[OK]${NC} Node updated and running!"
else
  echo -e "${CYAN}[INFO]${NC} Node restarting — check with: curl http://localhost:9090/health"
fi
