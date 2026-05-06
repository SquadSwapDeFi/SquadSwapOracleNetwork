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

# ── Auto-detect this host's public IP and persist as P2P_PUBLIC_IP ──
# Mirrors the same block in update.sh — see that script for the full
# rationale. In short: libp2p inside Docker only knows about loopback +
# bridge IPs, so without this the node broadcasts unroutable multiaddrs
# and the gossipsub mesh fragments. We write once here for fresh installs;
# update.sh handles the same logic for existing installs that pre-date
# this change. Idempotent: if the operator already set the value (manual
# IPv6, relay setup, etc), we don't overwrite.
if ! grep -qE "^[[:space:]]*P2P_PUBLIC_IP=" "$INSTALL_DIR/.env" 2>/dev/null; then
  DETECTED_IP=$(curl -fsSL -m 3 https://api.ipify.org 2>/dev/null \
    || curl -fsSL -m 3 https://icanhazip.com 2>/dev/null \
    || true)
  DETECTED_IP=$(printf '%s' "$DETECTED_IP" | tr -d '[:space:]')
  if [[ "$DETECTED_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '\nP2P_PUBLIC_IP=%s\n' "$DETECTED_IP" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
    ok "Detected public IP: ${DETECTED_IP} (saved to .env as P2P_PUBLIC_IP)"
  else
    warn "Could not detect public IP automatically. Set it manually in $INSTALL_DIR/.env"
    warn "  echo 'P2P_PUBLIC_IP=<your-public-ipv4>' | sudo tee -a $INSTALL_DIR/.env"
  fi
fi

# ── 4b. Pre-create the P2P data directory for the libp2p identity volume.
#     The container runs as the unprivileged `son` user (uid 10001 in the
#     alpine image). Make the host dir world-writable only for that uid —
#     avoids "permission denied" on first libp2p key write while keeping
#     the key readable only by its owner.
mkdir -p "$INSTALL_DIR/p2p-data"
# 10001 matches the son user created in packages/node/Dockerfile. If the
# Dockerfile user is ever changed, update this to match.
# Surface chown failures: if the container can't write its libp2p identity
# file, every restart generates a fresh peerId and silently invalidates
# every other operator's bootstrap entry for this node — that's worse than
# a visible setup error. Swallowing with `|| true` used to hide this.
if ! chown -R 10001:10001 "$INSTALL_DIR/p2p-data"; then
  err "Failed to chown $INSTALL_DIR/p2p-data to 10001:10001."
  err "The container runs as UID 10001 and needs ownership to persist its"
  err "libp2p identity. Without this, the peerId will change on every"
  err "restart and break other operators' P2P_BOOTSTRAP_NODES entries."
  err "Fix the filesystem permissions and re-run setup.sh."
  exit 1
fi
chmod 700 "$INSTALL_DIR/p2p-data"
ok "P2P identity volume ready at $INSTALL_DIR/p2p-data"

# ── 4c. Time sync sanity check ──
# The consensus layer rejects proposals whose timestamp is off by more than
# proposalMaxAgeSec (120s) from the follower's local clock. Two operators
# whose system clocks drift beyond that window will see every one of their
# rounds fail validation — a silent class of outage that's easy to miss if
# nothing surfaces the clock delta.
#
# On stock Ubuntu 24.04 (the DO one-click image) systemd-timesyncd is active
# by default, so this is mostly a warn-if-misconfigured check rather than an
# install step. If timedatectl reports the system clock as unsynchronized,
# we surface it loudly so the operator fixes it before chasing phantom
# consensus bugs. Not fatal — the node may still start and sync on its own.
if command -v timedatectl &>/dev/null; then
  TD_STATUS=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "")
  if [ "$TD_STATUS" = "yes" ]; then
    ok "System clock is NTP-synchronized"
  else
    warn "System clock is NOT NTP-synchronized (NTPSynchronized=${TD_STATUS:-unknown})."
    warn "Consensus rejects proposals whose timestamps drift >120s from peers."
    warn "Enable time sync: sudo timedatectl set-ntp true"
    warn "Verify once synced: timedatectl status"
  fi
else
  warn "timedatectl not found — can't verify NTP sync. Ensure system clock is"
  warn "within a few seconds of UTC, or consensus will reject this node's proposals."
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
# Three rules, all `ufw limit` (per-source-IP rate cap of 6 new connections in
# 30 seconds). The rate-limit absorbs brute-force / flood traffic without
# blocking legitimate use:
#
#   SSH   — MUST be first. ufw's default-deny policy kicks in the moment the
#           operator runs `ufw enable`; if no SSH rule exists at that point
#           the running SSH session gets dropped and the droplet becomes
#           unreachable except via the DO web console. Pre-staging the rule
#           guarantees SSH stays reachable across any later `ufw enable`.
#   9090  — HTTP API (/health, /metrics). Dashboard reads from here; the data
#           (prices, submission counts, operator wallet) is already public
#           on-chain, so exposing the port is intentional — Bearer-token auth
#           would be security theater on non-sensitive data. /logs stays gated
#           behind LOGS_TOKEN inside the application, which IS sensitive.
#   9091  — libp2p gossipsub. Public by necessity (peers dial in); rate-limit
#           neutralizes SYN-flood / connection-storm style abuse.
#
# We never auto-run `ufw enable` — that's the operator's call. Whether or not
# ufw is active, the rules are staged so that a future `enable` is safe.
if command -v ufw &>/dev/null; then
  # Detect the actual SSH port from sshd_config (default 22). Some operators
  # move SSH to a non-standard port for obscurity; limiting "22" in that case
  # would do nothing useful.
  SSH_PORT=$(grep -oE "^[[:space:]]*Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config 2>/dev/null \
    | awk '{print $2}' | tail -n1)
  SSH_PORT=${SSH_PORT:-22}

  # Idempotent ufw rule install. Keeps re-runs of setup.sh clean — without
  # this guard, running setup.sh twice would append a second LIMIT rule with
  # the same port+action, which bloats `ufw status` and confuses audits.
  # Uses `ufw show added` rather than `ufw status` because staged rules don't
  # appear in status until ufw is enabled.
  ensure_limit() {
    local port_proto="$1" description="$2"
    if ufw show added 2>/dev/null | grep -qE "ufw limit ${port_proto}\b"; then
      ok "Firewall: ${port_proto} already rate-limited (${description})"
      return 0
    fi
    # Drop any pre-existing ALLOW for the same port so the LIMIT doesn't get
    # shadowed (ALLOW matches first in ufw's rule order).
    ufw delete allow "${port_proto}" >/dev/null 2>&1 || true
    if ufw limit "${port_proto}" comment "${description}" >/dev/null 2>&1; then
      ok "Firewall: ufw LIMIT rule added for ${port_proto} (${description})"
    else
      warn "ufw present but failed to add ${port_proto} rule"
    fi
  }

  ensure_limit "${SSH_PORT}/tcp" "SSH (rate-limited)"
  ensure_limit "9090/tcp"        "SON HTTP API (rate-limited)"
  ensure_limit "9091/tcp"        "SON libp2p gossipsub (rate-limited)"

  # Warn if ufw is installed but inactive so the operator understands the rules
  # above aren't actually enforcing anything until they enable it.
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw is installed but INACTIVE — rules above are staged, not enforced."
    warn "Before running 'sudo ufw enable', verify with 'sudo ufw status verbose' that"
    warn "SSH (${SSH_PORT}/tcp) shows up as LIMIT, otherwise enabling will lock you out."
  fi
else
  warn "ufw not found — if you use another firewall (iptables / cloud security group):"
  warn "  - allow SSH from your admin IP(s)"
  warn "  - allow 9090/tcp (HTTP API, public-by-design)"
  warn "  - allow 9091/tcp (libp2p — required for multi-operator P2P)"
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
# Branch the closing guidance on whether the canonical .env.example shipped a
# populated bootstrap list or not. If it did, the node auto-joins the mesh
# with zero extra steps; the operator only needs to share their own multiaddr
# so it can be added to the canonical list in a future commit. If the list
# is empty (genesis phase), the first cohort needs to collect peerIds and
# commit them upstream — after which all nodes re-sync on `update.sh`.
HAS_BOOTSTRAP=$(grep -E "^P2P_BOOTSTRAP_NODES=[^[:space:]]+" "$INSTALL_DIR/.env" 2>/dev/null || true)

echo -e "  ${CYAN}Multi-operator P2P is enabled by default:${NC}"
if [ -n "$HAS_BOOTSTRAP" ]; then
  echo -e "  ✓ Bootstrap peers pre-configured from the repo's canonical list — this node"
  echo -e "    will auto-join the mesh. Confirm peers connected after a minute:"
  echo -e "       docker compose -f $INSTALL_DIR/docker-compose.yml logs --tail 200 | grep -E 'peerId|Multi-op round'"
  echo ""
  echo -e "  To have YOUR node added to the canonical list (so future operators auto-dial"
  echo -e "  you on install):"
  echo -e "    1. Get your peerId:"
  echo -e "       docker compose -f $INSTALL_DIR/docker-compose.yml logs --tail 200 | grep peerId"
  echo -e "    2. Share your full multiaddr with the team:"
  echo -e "       /ip4/<this-server-public-ip>/tcp/9091/p2p/<peerId>"
  echo -e "    3. It will be merged into .env.example in the repo; every node picks it up"
  echo -e "       on the next 'sudo bash update.sh' run."
else
  echo -e "  No bootstrap peers configured yet (genesis phase)."
  echo -e "  1. Get your peerId:"
  echo -e "     docker compose -f $INSTALL_DIR/docker-compose.yml logs --tail 200 | grep peerId"
  echo -e "  2. Share your multiaddr with the other operators:"
  echo -e "     /ip4/<this-server-public-ip>/tcp/9091/p2p/<peerId>"
  echo -e "  3. Once all peerIds are collected, commit them into .env.example's"
  echo -e "     P2P_BOOTSTRAP_NODES (comma-separated) in the repo and push."
  echo -e "  4. Every node running 'sudo bash update.sh' will then pick up the canonical"
  echo -e "     list automatically and join the mesh."
fi
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
