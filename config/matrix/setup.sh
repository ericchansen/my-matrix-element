#!/bin/bash
set -euo pipefail

# Matrix + Element setup script for the OpenClaw VM.
# Run this ON the VM (via SSH) after copying the config files.
#
# Usage:
#   ./setup.sh <server-fqdn>
#
# Example:
#   ./setup.sh openclaw-abc123.centralus.cloudapp.azure.com

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_NAME="${1:-}"

if [ -z "$SERVER_NAME" ]; then
  echo "Usage: $0 <server-fqdn>"
  echo "Example: $0 openclaw-abc123.centralus.cloudapp.azure.com"
  exit 1
fi

echo "=== Matrix + Element Setup ==="
echo "Server: $SERVER_NAME"
echo ""

# --- 1. Install Docker if not present ---
if ! command -v docker &> /dev/null; then
  echo ">>> Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "Docker installed. You may need to log out and back in for group membership."
  echo "Then re-run this script."
  # Check if we can use docker without re-login via newgrp
  if ! docker info &> /dev/null 2>&1; then
    echo ""
    echo "Please log out, log back in, and re-run: $0 $SERVER_NAME"
    exit 0
  fi
else
  echo ">>> Docker already installed ✓"
fi

# --- 2. Create working directory ---
MATRIX_DIR="$HOME/matrix"
mkdir -p "$MATRIX_DIR"
echo ">>> Working directory: $MATRIX_DIR"

# --- 3. Copy config files ---
echo ">>> Copying config files..."
cp "$SCRIPT_DIR/docker-compose.yml" "$MATRIX_DIR/"
cp "$SCRIPT_DIR/Caddyfile" "$MATRIX_DIR/"
cp "$SCRIPT_DIR/element-config.json" "$MATRIX_DIR/"

# --- 4. Generate .env file ---
if [ ! -f "$MATRIX_DIR/.env" ]; then
  # Use alphanumeric-only password to avoid sed/shell escaping issues
  PG_PASS=$(openssl rand -hex 16)
  cat > "$MATRIX_DIR/.env" << EOF
MATRIX_SERVER_NAME=$SERVER_NAME
POSTGRES_PASSWORD=$PG_PASS
EOF
  echo ">>> Generated .env with random PostgreSQL password ✓"
  echo ""
  echo "╔════════════════════════════════════════════════════╗"
  echo "║  ⚠️  BACK UP YOUR CREDENTIALS!                    ║"
  echo "║  The .env file contains your database password.   ║"
  echo "║  If the VM is lost, the database is unrecoverable.║"
  echo "║  File: $MATRIX_DIR/.env                           ║"
  echo "╚════════════════════════════════════════════════════╝"
  echo ""
else
  echo ">>> .env already exists, updating MATRIX_SERVER_NAME..."
  sed -i "s|^MATRIX_SERVER_NAME=.*|MATRIX_SERVER_NAME=$SERVER_NAME|" "$MATRIX_DIR/.env"
fi

# Source the env file for variable substitution
set -a
source "$MATRIX_DIR/.env"
set +a

# --- 5. Update element-config.json with actual server name ---
# Always copy from template to make this idempotent
cp "$SCRIPT_DIR/element-config.json" "$MATRIX_DIR/element-config.json"
sed -i "s|MATRIX_SERVER_NAME_PLACEHOLDER|$SERVER_NAME|g" "$MATRIX_DIR/element-config.json"
echo ">>> Updated element-config.json with $SERVER_NAME ✓"

# --- 6. Generate Synapse config ---
cd "$MATRIX_DIR"
SYNAPSE_GENERATED_MARKER="$MATRIX_DIR/.synapse-generated"
if [ ! -f "$SYNAPSE_GENERATED_MARKER" ]; then
  echo ">>> Generating Synapse configuration..."
  docker run --rm \
    -v matrix_synapse-data:/data \
    -e SYNAPSE_SERVER_NAME="$SERVER_NAME" \
    -e SYNAPSE_REPORT_STATS=no \
    matrixdotorg/synapse:latest generate
  touch "$SYNAPSE_GENERATED_MARKER"
  echo ">>> Synapse config generated ✓"
else
  echo ">>> Synapse config already exists ✓"
fi

# --- 7. Patch homeserver.yaml for PostgreSQL ---
echo ">>> Configuring Synapse to use PostgreSQL..."
# We need to modify the generated config inside the Docker volume
docker run --rm \
  -v matrix_synapse-data:/data \
  --entrypoint /bin/sh \
  matrixdotorg/synapse:latest -c "
    # Replace SQLite config with PostgreSQL
    if grep -q 'sqlite3' /data/homeserver.yaml; then
      sed -i '/^database:/,/^[a-z]/{
        /^database:/c\\
database:\\
  name: psycopg2\\
  args:\\
    user: synapse\\
    password: \"$POSTGRES_PASSWORD\"\\
    database: synapse\\
    host: matrix-postgres\\
    cp_min: 2\\
    cp_max: 5
        /^  name: sqlite3/d
        /^  args:/d
        /^    database:/d
      }' /data/homeserver.yaml
      echo 'Patched database config to PostgreSQL'
    else
      echo 'Database already configured (not sqlite3)'
    fi

    # Enable experimental features for Element X / Sliding Sync
    if ! grep -q 'msc3575_enabled' /data/homeserver.yaml; then
      cat >> /data/homeserver.yaml << 'YAMLEOF'

# Element X / Sliding Sync support
experimental_features:
  msc3575_enabled: true
YAMLEOF
      echo 'Added Sliding Sync support'
    fi

    # Set public_baseurl
    if ! grep -q 'public_baseurl' /data/homeserver.yaml; then
      echo \"public_baseurl: \\\"https://$SERVER_NAME\\\"\" >> /data/homeserver.yaml
      echo 'Added public_baseurl'
    fi

    # Trust the Caddy reverse proxy
    if ! grep -q 'x_forwarded' /data/homeserver.yaml; then
      sed -i 's/- port: 8008/- port: 8008\\n    x_forwarded: true/' /data/homeserver.yaml
      echo 'Added x_forwarded: true'
    fi
  "
echo ">>> Synapse configured for PostgreSQL ✓"

# --- 8. Set up mautrix-discord bridge ---
DISCORD_DIR="$MATRIX_DIR/mautrix-discord"
if [ ! -f "$DISCORD_DIR/config.yaml" ]; then
  echo ">>> Setting up Discord bridge..."
  mkdir -p "$DISCORD_DIR"

  # Create a separate database for the bridge
  docker exec matrix-postgres psql -U synapse -c "SELECT 1 FROM pg_database WHERE datname='mautrix_discord'" | grep -q 1 || \
    docker exec matrix-postgres psql -U synapse -c "CREATE DATABASE mautrix_discord OWNER synapse;"
  echo ">>> Discord bridge database ready ✓"

  # Generate default config
  docker run --rm -v "$DISCORD_DIR:/data:z" dock.mau.dev/mautrix/discord:latest
  echo ">>> Discord bridge default config generated ✓"

  # Patch the config for our setup
  sed -i "s|address: https://matrix-client.matrix.org|address: http://synapse:8008|" "$DISCORD_DIR/config.yaml"
  sed -i "s|domain: matrix.org|domain: $SERVER_NAME|" "$DISCORD_DIR/config.yaml"
  sed -i "s|address: http://localhost:29334|address: http://mautrix-discord:29334|" "$DISCORD_DIR/config.yaml"
  # Configure bridge to use PostgreSQL
  sed -i "s|uri: sqlite:///data/mautrix-discord.db|uri: postgres://synapse:${POSTGRES_PASSWORD}@matrix-postgres/mautrix_discord?sslmode=disable|" "$DISCORD_DIR/config.yaml"
  # Set permissions so our admin can use the bridge
  sed -i "s|\"\\*\": relay|\"$SERVER_NAME\": user\n        \"@eric:$SERVER_NAME\": admin|" "$DISCORD_DIR/config.yaml"

  echo ">>> Discord bridge config patched ✓"

  # Generate the appservice registration file
  docker run --rm -v "$DISCORD_DIR:/data:z" dock.mau.dev/mautrix/discord:latest
  echo ">>> Discord bridge registration generated ✓"

  # Register the bridge with Synapse
  docker run --rm \
    -v matrix_synapse-data:/data \
    -v "$DISCORD_DIR/registration.yaml:/bridge-registration.yaml:ro" \
    --entrypoint /bin/sh \
    matrixdotorg/synapse:latest -c "
      mkdir -p /data/bridges
      cp /bridge-registration.yaml /data/bridges/mautrix-discord.yaml
      if ! grep -q 'app_service_config_files' /data/homeserver.yaml; then
        cat >> /data/homeserver.yaml << 'YAMLEOF'

app_service_config_files:
  - /data/bridges/mautrix-discord.yaml
YAMLEOF
        echo 'Registered Discord bridge with Synapse'
      elif ! grep -q 'mautrix-discord' /data/homeserver.yaml; then
        sed -i '/app_service_config_files:/a\\  - /data/bridges/mautrix-discord.yaml' /data/homeserver.yaml
        echo 'Added Discord bridge to existing appservice list'
      else
        echo 'Discord bridge already registered'
      fi
    "
  echo ">>> Discord bridge registered with Synapse ✓"
else
  echo ">>> Discord bridge already configured ✓"
fi

# --- 9. Start the stack ---
echo ">>> Starting Matrix stack..."
docker compose up -d
echo ""

# Restart Synapse to pick up the bridge registration
docker compose restart synapse
echo ">>> Synapse restarted to load bridge ✓"

# --- 10. Wait for Synapse to be ready ---
echo ">>> Waiting for Synapse to start..."
for i in $(seq 1 30); do
  if docker exec synapse curl -sf http://localhost:8008/_matrix/client/versions > /dev/null 2>&1; then
    echo ">>> Synapse is ready ✓"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "WARNING: Synapse didn't become ready in 30 seconds. Check logs:"
    echo "  docker logs synapse"
    exit 1
  fi
  sleep 2
done

# --- 12. Done! ---
echo ""
echo "============================================"
echo "  Matrix + Element is running! 🎉"
echo "============================================"
echo ""
echo "  Element Web:  https://$SERVER_NAME"
echo "  Synapse API:  https://$SERVER_NAME/_matrix/client/versions"
echo ""
echo "  Discord Bridge:"
echo "    1. Open Element, start a chat with @discordbot:$SERVER_NAME"
echo "    2. Send: login-token"
echo "    3. Follow the link to authorize with Discord"
echo "    4. Your Discord servers will appear as Matrix rooms!"
echo ""
echo "  View logs:"
echo "    docker compose -f $MATRIX_DIR/docker-compose.yml logs -f"
echo ""
echo "  Stop:"
echo "    docker compose -f $MATRIX_DIR/docker-compose.yml down"
echo ""
echo "  ⚠️  Get a custom domain before inviting others!"
echo "      Matrix user IDs (@user:server) are PERMANENT."
echo "============================================"
