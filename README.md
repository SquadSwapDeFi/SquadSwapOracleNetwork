# Squad Oracle Network — Node Setup

Run a Squad Oracle Network operator node with a single command.

## Quick Start

> **Security note:** Piping scripts directly into `bash` skips integrity verification.
> For production environments, download the script first, review it, then run:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/SquadSwapDeFi/SquadSwapOracleNetwork/main/setup.sh -o setup.sh
> less setup.sh        # review the script
> sudo bash setup.sh
> ```

Or use the one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/SquadSwapDeFi/SquadSwapOracleNetwork/main/setup.sh | sudo bash
```

This will:
1. Install Docker (if not present)
2. Generate a new operator wallet
3. Download and start the node container
4. Create a systemd service for auto-restart

## After Setup

1. **View your private key** — `sudo cat /opt/son-node/.env | grep OPERATOR_PRIVATE_KEY`
2. **Import the key** into MetaMask or your preferred wallet to see your address
3. **Send BNB** to the wallet (for gas fees)
4. **Send SQUAD** tokens to the wallet (for staking)
5. **Stake** at [oracle.squadswap.com](https://oracle.squadswap.com)

## Minimum Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| OS | Ubuntu 22.04+ (or any Linux with systemd) | Ubuntu 24.04 LTS |
| CPU | 1 vCPU | 2 vCPU |
| RAM | 2 GB | 4 GB |
| Disk | 10 GB | 20 GB SSD |
| Network | Stable internet; port 9090 reachable locally only (keep firewalled from public) | Low-latency connection |
| Access | Root (sudo) | Root (sudo) |

**Wallet requirements:**
- BNB for gas fees (~0.01 BNB to start)
- SQUAD tokens for staking (minimum 100000 SQUAD)

## Commands

| Action | Command |
|--------|---------|
| View logs | `docker compose -f /opt/son-node/docker-compose.yml logs -f` |
| Restart | `systemctl restart son-node` |
| Stop | `systemctl stop son-node` |
| Health check | `curl http://localhost:9090/health` |

## Viewing recent logs over HTTP (optional)

If you prefer to check the last ~500 log lines from a browser without SSH, set a
random `LOGS_TOKEN` in `/opt/son-node/.env`:

```bash
# 1. Generate a token and print it so you can copy it
TOKEN=$(openssl rand -hex 32)
echo "Your LOGS_TOKEN is: $TOKEN"

# 2. Append it to the node's .env file
echo "LOGS_TOKEN=$TOKEN" | sudo tee -a /opt/son-node/.env > /dev/null

# 3. Restart so the node picks it up
sudo systemctl restart son-node
```

Copy the value printed in step 1. Then from a machine that can reach the node
(use an SSH tunnel, VPN, or local network; never from the public internet), send
the token in an `Authorization` header — it must NOT be passed in the URL, since
query strings routinely leak into proxy/access logs.

```bash
curl -H "Authorization: Bearer <paste-the-token-here>" http://<node-ip>:9090/logs
```

You can also retrieve the token later with:

```bash
sudo grep LOGS_TOKEN /opt/son-node/.env
```

**Leave the token unset (default) to disable the endpoint entirely.** Even with a
token set, keep port 9090 firewalled from the public internet — the token is a
secondary defence, not a replacement for network-level access control.

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/SquadSwapDeFi/SquadSwapOracleNetwork/main/update.sh | sudo bash
```

Pulls the latest image and restarts. Your wallet and configuration are preserved.

## Configuration

Config file: `/opt/son-node/.env`

See [.env.example](.env.example) for all available options.

## Links

- [SquadSwap](https://squadswap.com)
- [Oracle Dashboard](https://oracle.squadswap.com)
- [Documentation](https://oracle.squadswap.com/dashboard/docs)
