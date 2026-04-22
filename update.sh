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
ENV_EXAMPLE_URL="${REPO_BASE}/.env.example"
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

trap 'rm -f /tmp/son-checksums.sha256 /tmp/son-env-example' EXIT

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

# ── Sync new env vars from .env.example into existing .env ──
echo -e "${CYAN}[INFO]${NC} Checking for new config variables..."
ENV_EXAMPLE_FETCHED=0
if curl -fsSL "$ENV_EXAMPLE_URL" -o /tmp/son-env-example 2>/dev/null; then
  ENV_EXAMPLE_FETCHED=1
  ADDED=0
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    KEY="${line%%=*}"
    # If key doesn't exist in current .env, append it
    if ! grep -q "^${KEY}=" "$INSTALL_DIR/.env" 2>/dev/null; then
      echo "$line" >> "$INSTALL_DIR/.env"
      echo -e "${GREEN}[NEW]${NC} Added config: ${KEY}"
      ADDED=$((ADDED + 1))
    fi
  done < /tmp/son-env-example
  if [ "$ADDED" -eq 0 ]; then
    echo -e "${GREEN}[OK]${NC} Config up to date"
  else
    echo -e "${GREEN}[OK]${NC} Added $ADDED new config variable(s)"
  fi
else
  echo -e "${CYAN}[INFO]${NC} Could not fetch .env.example — skipping config sync"
fi

# ── Sync P2P_BOOTSTRAP_NODES from canonical .env.example ──
# .env.example in the repo is the source of truth for the bootstrap peer list
# — every node should see the same mesh entrypoints. We only overwrite the
# bootstrap value; operator-specific keys (OPERATOR_PRIVATE_KEY, LOGS_TOKEN,
# custom RPC overrides) are left alone. The only way to change the canonical
# list is to commit to .env.example — patching each node by hand would drift
# out of sync and get reset on the next update.
if [ "$ENV_EXAMPLE_FETCHED" -eq 1 ]; then
  # `tr -d '\r'` is defensive: if the upstream .env.example ever gets rewritten
  # with CRLF line endings (CI tooling, an editor misconfiguration, a sloppy
  # patch), a trailing '\r' on the value slides into the multiaddr and breaks
  # libp2p dial parsing with errors that are hard to pattern-match. Stripping
  # at read-time costs nothing and removes that whole failure class.
  NEW_BOOTSTRAP=$(grep -E "^P2P_BOOTSTRAP_NODES=" /tmp/son-env-example 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r' || true)
  CUR_BOOTSTRAP=$(grep -E "^P2P_BOOTSTRAP_NODES=" "$INSTALL_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' || true)
  if [ "$NEW_BOOTSTRAP" != "$CUR_BOOTSTRAP" ]; then
    # Back up the current .env so the operator can recover any ad-hoc tweaks.
    cp -p "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.$(date +%Y%m%d%H%M%S).bak"
    # sed delimiter '|' avoids escaping the many '/' in multiaddrs. Escape
    # only the characters sed treats specially in the replacement string.
    ESC=$(printf '%s' "$NEW_BOOTSTRAP" | sed -e 's/[\&|]/\\&/g')
    if grep -qE "^[[:space:]]*P2P_BOOTSTRAP_NODES=" "$INSTALL_DIR/.env"; then
      sed -i "s|^[[:space:]]*P2P_BOOTSTRAP_NODES=.*|P2P_BOOTSTRAP_NODES=${ESC}|" "$INSTALL_DIR/.env"
    else
      printf '\nP2P_BOOTSTRAP_NODES=%s\n' "$NEW_BOOTSTRAP" >> "$INSTALL_DIR/.env"
    fi
    chmod 600 "$INSTALL_DIR/.env"
    if [ -n "$NEW_BOOTSTRAP" ]; then
      echo -e "${GREEN}[OK]${NC} P2P_BOOTSTRAP_NODES synced from canonical .env.example"
    else
      echo -e "${CYAN}[INFO]${NC} P2P_BOOTSTRAP_NODES cleared — canonical list is empty (genesis phase?)"
    fi
  fi
fi

# ── Make sure the libp2p identity volume exists and is owned by the container
#    user. Fresh installs created this in setup.sh; old installs upgrading into
#    the P2P build need it too, so idempotent-create here.
mkdir -p "$INSTALL_DIR/p2p-data"
# Matches setup.sh behavior: surface chown failures instead of swallowing them.
# If the container (UID 10001) can't write its libp2p identity file, every
# restart regenerates the peerId and invalidates other operators' bootstrap
# entries for this node — a silent failure mode worse than an aborted update.
if ! chown -R 10001:10001 "$INSTALL_DIR/p2p-data"; then
  echo -e "${RED}[ERROR]${NC} Failed to chown $INSTALL_DIR/p2p-data to 10001:10001." >&2
  echo -e "${RED}[ERROR]${NC} The container runs as UID 10001 and needs ownership to persist its" >&2
  echo -e "${RED}[ERROR]${NC} libp2p identity. Without this, the peerId will change on every restart" >&2
  echo -e "${RED}[ERROR]${NC} and break other operators' P2P_BOOTSTRAP_NODES entries." >&2
  echo -e "${RED}[ERROR]${NC} Fix the filesystem permissions and re-run update.sh." >&2
  exit 1
fi
chmod 700 "$INSTALL_DIR/p2p-data"

# ── Firewall — three rules under `ufw limit` (per-source-IP rate cap) ──
#
# SSH MUST be first so that a subsequent `ufw enable` doesn't drop the running
# SSH session (ufw's default-deny policy kicks in the instant it's enabled,
# and without an SSH rule the operator loses access until they reach the DO
# web console). 9090 and 9091 are both intentionally public — /health and
# /metrics expose on-chain data, /logs is gated in-app by LOGS_TOKEN, and
# 9091 is libp2p gossipsub. `ufw limit` neutralizes connection-flood abuse
# without blocking legitimate dashboard / peer traffic.
#
# We never auto-run `ufw enable` — the operator decides when to activate.
FIREWALL_WARN=""
if command -v ufw &>/dev/null; then
  # Detect the actual SSH port from sshd_config (default 22). If the operator
  # moved SSH to a non-standard port, limiting 22 would do nothing useful.
  SSH_PORT=$(grep -oE "^[[:space:]]*Port[[:space:]]+[0-9]+" /etc/ssh/sshd_config 2>/dev/null \
    | awk '{print $2}' | tail -n1)
  SSH_PORT=${SSH_PORT:-22}

  # ensure_limit <port>/tcp <description>: idempotent migration helper.
  # - Already LIMIT → no-op
  # - Pre-existing ALLOW (from older setup.sh runs) → delete then re-add as
  #   LIMIT (ALLOW matches first and would shadow LIMIT if kept)
  # - Nothing staged → add LIMIT
  #
  # Use `ufw show added` rather than `ufw status`: the latter only prints
  # rules when ufw is ACTIVE, which means on a freshly-installed droplet
  # (ufw staged but not yet enabled) the idempotency check would always
  # report "not found" and we'd re-emit "LIMIT rule added" on every run.
  # `ufw show added` lists staged rules regardless of active state.
  ensure_limit() {
    local port_proto="$1" description="$2"
    if ufw show added 2>/dev/null | grep -qE "ufw limit ${port_proto}\b"; then
      echo -e "${CYAN}[INFO]${NC} Firewall: ${port_proto} already rate-limited (${description})"
      return 0
    fi
    ufw delete allow "${port_proto}" >/dev/null 2>&1 || true
    if ufw limit "${port_proto}" comment "${description}" >/dev/null 2>&1; then
      echo -e "${GREEN}[OK]${NC} Firewall: ufw LIMIT rule added for ${port_proto} (${description})"
    else
      FIREWALL_WARN="ufw rule add failed for ${port_proto} — verify manually"
    fi
  }

  ensure_limit "${SSH_PORT}/tcp" "SSH (rate-limited)"
  ensure_limit "9090/tcp"        "SON HTTP API (rate-limited)"
  ensure_limit "9091/tcp"        "SON libp2p gossipsub (rate-limited)"

  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    FIREWALL_WARN="ufw INACTIVE — rules staged but not enforced. Before 'sudo ufw enable', run 'sudo ufw status verbose' and confirm ${SSH_PORT}/tcp is LIMIT, otherwise enabling will lock you out."
  fi
else
  FIREWALL_WARN="ufw not installed — if using another firewall (iptables / cloud SG): allow SSH from your admin IP, 9090/tcp (HTTP API), 9091/tcp (libp2p)"
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

# ── Post-update guidance for operators moving into multi-operator mode.
#    Surface the peerId + full multiaddr so they can share it directly.
P2P_ENABLED=$(grep -E "^P2P_ENABLED=" "$INSTALL_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
PEER_ID=$(docker compose logs --tail 500 son-node 2>/dev/null | grep -oE "peerId=[A-Za-z0-9]+" | tail -n1 | cut -d= -f2 || true)

echo ""
if [ "$P2P_ENABLED" = "true" ]; then
  if [ -n "$PEER_ID" ]; then
    PUBLIC_IP=$(curl -fsSL -m 3 https://api.ipify.org 2>/dev/null || echo "<YOUR_PUBLIC_IP>")
    echo -e "${GREEN}[OK]${NC} P2P is enabled. Share this multiaddr with other operators:"
    echo -e "       /ip4/${PUBLIC_IP}/tcp/9091/p2p/${PEER_ID}"
  else
    echo -e "${CYAN}[INFO]${NC} P2P is enabled but peerId not found in logs yet — give it a few seconds and run:"
    echo -e "       docker compose -f $INSTALL_DIR/docker-compose.yml logs --tail 200 | grep peerId"
  fi
else
  echo -e "${CYAN}[INFO]${NC} P2P is disabled (P2P_ENABLED=false). Single-operator mode — no action needed."
  echo -e "       To join multi-operator consensus: edit .env, set P2P_ENABLED=true + P2P_BOOTSTRAP_NODES=..., then restart."
fi

if [ -n "$FIREWALL_WARN" ]; then
  echo ""
  echo -e "${RED}[FIREWALL]${NC} $FIREWALL_WARN"
fi
