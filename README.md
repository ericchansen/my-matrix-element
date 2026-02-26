# my-matrix

Matrix + Element deployment for the existing OpenClaw VM (`Standard_B2pls_v2`, ARM64, Ubuntu 24.04).

## Architecture

```
┌──────────────── Azure VM (openclaw-vm) ────────────────┐
│                                                         │
│  Native:   OpenClaw gateway (systemd, port 18789)       │
│                                                         │
│  Docker Compose:                                        │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐ ┌─────────┐  │
│  │  Synapse  │ │ Postgres │ │ Element Web│ │  Caddy  │  │
│  │  :8008    │ │  :5432   │ │   :80      │ │:443/:80 │  │
│  └──────────┘ └──────────┘ └────────────┘ └─────────┘  │
│                Docker network: matrix                    │
└─────────────────────────────────────────────────────────┘
```

## Quick Start

```bash
# 1. Open NSG ports (from local machine)
cd ~/repos/my-openclaw
# Deploy updated main.bicep with HTTP/HTTPS rules

# 2. SSH into VM and install Docker
ssh azureuser@<VM_FQDN>
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker azureuser

# 3. Copy config and start
# (see config/matrix/ for docker-compose.yml, Caddyfile, etc.)
docker compose -f config/matrix/docker-compose.yml up -d

# 4. Create admin user
docker exec -it synapse register_new_matrix_user -c /data/homeserver.yaml http://localhost:8008
```

## Files

| File | Purpose |
|------|---------|
| `config/matrix/docker-compose.yml` | Synapse + PostgreSQL + Element Web + Caddy |
| `config/matrix/Caddyfile` | Reverse proxy with auto-TLS |
| `config/matrix/element-config.json` | Element Web homeserver config |
| `config/matrix/setup.sh` | VM-side setup script |

## TODO

- [ ] Get a custom domain (Matrix IDs are permanent — `@user:yourdomain.com`)
- [ ] Configure federation
- [ ] Set up bridges (Discord, Slack, etc.)
- [ ] Backups (PostgreSQL + Synapse media)
