#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════
#  Squad Oracle Network — One-Click Node Setup
#  https://github.com/SquadSwapDeFi/SquadSwapOracleNetwork
# ═══════════════════════════════════════════════════════

INSTALL_DIR="/opt/son-node"
REPO_BASE="https://raw.githubusercontent.com/SquadSwapDeFi/SquadSwapOracleNetwork/main"
COMPOSE_URL="${REPO_BASE}/docker-compose.yml"
ENV_EXAMPLE_URL="${REPO_BASE}/.env.example"
CHECKSUMS_URL="${REPO_BASE}/checksums.sha256"
IMAGE="ghcr.io/squadswapdefi/son-node:latest"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Root check ──
if [ "$EUID" -ne 0 ]; then
  err "Please run as root: sudo bash setup.sh"
  exit 1
fi

trap 'rm -f /tmp/son-checksums.sha256' EXIT

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Squad Oracle Network — Node Setup${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""

# ── 0. Prerequisites ──
for cmd in curl openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    err "$cmd is required but not installed. Run: apt-get install -y $cmd"
    exit 1
  fi
done

# ── 1. Install Docker ──
if command -v docker &>/dev/null; then
  ok "Docker already installed: $(docker --version)"
else
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  ok "Docker installed"
fi

# ── 2. Install Docker Compose plugin ──
if docker compose version &>/dev/null; then
  ok "Docker Compose available: $(docker compose version)"
else
  info "Installing Docker Compose plugin..."
  apt-get update -qq && apt-get install -y -qq docker-compose-plugin
  ok "Docker Compose installed"
fi

# ── 3. Create install directory ──
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"
info "Install directory: $INSTALL_DIR"

# ── 4. Generate operator wallet ──
if [ -f "$INSTALL_DIR/.env" ] && grep -q "OPERATOR_PRIVATE_KEY" "$INSTALL_DIR/.env"; then
  warn "Existing .env found — skipping wallet generation"
  warn "To generate a new wallet, delete $INSTALL_DIR/.env and re-run"
else
  info "Generating new operator wallet..."
  PRIVATE_KEY=$(openssl rand -hex 32)

  # Create .env with restricted permissions BEFORE writing secrets
  (umask 077 && curl -fsSL "$ENV_EXAMPLE_URL" -o "$INSTALL_DIR/.env")
  chmod 600 "$INSTALL_DIR/.env"
  sed -i "s|^OPERATOR_PRIVATE_KEY=.*|OPERATOR_PRIVATE_KEY=0x${PRIVATE_KEY}|" "$INSTALL_DIR/.env"

  # Never echo the private key to terminal — it persists in shell history,
  # screen/tmux scrollback, and CI logs. The key is only in .env (mode 600).
  ok "Operator private key written to $INSTALL_DIR/.env (permissions: 600)"
  warn "Import the key from .env into MetaMask to see your wallet address"
  warn "View key: sudo cat $INSTALL_DIR/.env | grep OPERATOR_PRIVATE_KEY"
fi

# ── 5. Download docker-compose.yml with checksum verification ──
info "Downloading docker-compose.yml..."
curl -fsSL "$COMPOSE_URL" -o "$INSTALL_DIR/docker-compose.yml"
info "Verifying file integrity..."
curl -fsSL "$CHECKSUMS_URL" -o /tmp/son-checksums.sha256
EXPECTED=$(awk '$2 == "docker-compose.yml" {print $1}' /tmp/son-checksums.sha256)
if [ -n "$EXPECTED" ]; then
  ACTUAL=$(sha256sum "$INSTALL_DIR/docker-compose.yml" | awk '{print $1}')
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    err "Checksum mismatch for docker-compose.yml!"
    err "Expected: $EXPECTED"
    err "Actual:   $ACTUAL"
    err "The file may have been tampered with. Aborting."
    rm -f "$INSTALL_DIR/docker-compose.yml"
    exit 1
  fi
  ok "Checksum verified"
else
  err "Checksum entry for docker-compose.yml not found in checksums.sha256"
  err "The checksum file may be corrupt or tampered with. Aborting."
  rm -f "$INSTALL_DIR/docker-compose.yml"
  exit 1
fi

# ── 6. Pull image ──
info "Pulling $IMAGE ..."
docker pull "$IMAGE"
ok "Image pulled"

# ── 7. Create systemd service ──
cat > /etc/systemd/system/son-node.service <<EOF
[Unit]
Description=Squad Oracle Network Node
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable son-node
systemctl start son-node
ok "systemd service created and started"

# ── 8. Firewall ──
if command -v ufw &>/dev/null; then
  ufw allow 9090/tcp comment "SON Node API" >/dev/null 2>&1 || true
  ok "Firewall: port 9090 opened"
else
  warn "ufw not found — manually open port 9090 if needed"
fi

# ── 9. Health check ──
info "Waiting for node to start..."
sleep 5
if curl -sf http://localhost:9090/health >/dev/null 2>&1; then
  ok "Node is running!"
else
  warn "Node not yet responding — it may still be starting up"
  warn "Check with: curl http://localhost:9090/health"
fi

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Squad Oracle Network — Setup Complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Next steps:${NC}"
echo -e "  1. View your private key: ${YELLOW}sudo cat $INSTALL_DIR/.env | grep OPERATOR_PRIVATE_KEY${NC}"
echo -e "  2. Import the private key into MetaMask to see your wallet address"
echo -e "  3. Send BNB to the wallet address (for gas fees)"
echo -e "  4. Send SQUAD tokens to the wallet address"
echo -e "  5. Go to https://oracle.squadswap.com and stake your SQUAD"
echo ""
echo -e "  ${CYAN}Useful commands:${NC}"
echo -e "  View logs:    docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
echo -e "  Restart:      systemctl restart son-node"
echo -e "  Stop:         systemctl stop son-node"
echo -e "  Health check: curl http://localhost:9090/health"
echo -e "  Update:       curl -fsSL https://raw.githubusercontent.com/SquadSwapDeFi/SquadSwapOracleNetwork/main/update.sh | sudo bash"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
