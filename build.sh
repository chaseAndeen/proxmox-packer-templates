#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build.sh — Builds a Packer golden image template on Proxmox
#
# Usage:
#   ./build.sh ubuntu-noble
#   ./build.sh debian-trixie
#
# Requirements (one-time setup on the build machine):
#   1. WSL2 mirrored networking — add to C:\Users\<you>\.wslconfig:
#        [wsl2]
#        networkingMode=mirrored
#      Then run: wsl --shutdown
#
#   2. Windows Firewall rule for Debian preseed HTTP server:
#        New-NetFirewallRule -DisplayName "Packer Preseed HTTP" \
#          -Direction Inbound -Protocol TCP -LocalPort 8118 -Action Allow
#
# Environment overrides:
#   AWS_PROFILE           — AWS CLI profile         (default: InfraProvisioner)
#   AWS_REGION            — AWS region              (default: us-east-1)
#   UBUNTU_TEMPLATE_ID    — Proxmox VM ID for Ubuntu template (default: 9000)
#   DEBIAN_TEMPLATE_ID    — Proxmox VM ID for Debian template (default: 9001)
# ---------------------------------------------------------------------------

set -euo pipefail

TARGET="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-InfraProvisioner}"
AWS_REGION="${AWS_REGION:-us-east-1}"
UBUNTU_TEMPLATE_ID="${UBUNTU_TEMPLATE_ID:-9000}"
DEBIAN_TEMPLATE_ID="${DEBIAN_TEMPLATE_ID:-9001}"
PRESEED_PORT="8118"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

if [[ -z "$TARGET" ]]; then
  echo "Usage: $0 <ubuntu-noble|debian-trixie>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDS_DIR="$SCRIPT_DIR/builds"
VARS_FILE="$SCRIPT_DIR/variables.pkrvars.hcl"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

echo "==> Running preflight checks..."

# vars file exists
if [[ ! -f "$VARS_FILE" ]]; then
  echo "ERROR: variables.pkrvars.hcl not found."
  echo "       Copy variables.pkrvars.hcl.example to variables.pkrvars.hcl and fill in your values."
  exit 1
fi

# build file exists
if [[ ! -f "$BUILDS_DIR/${TARGET}.pkr.hcl" ]]; then
  echo "ERROR: No build file found for '$TARGET'."
  echo "       Expected: $BUILDS_DIR/${TARGET}.pkr.hcl"
  exit 1
fi

# required tools
for tool in packer ansible aws python3; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' is not installed or not in PATH."
    exit 1
  fi
done

# xorriso required for ubuntu (builds cidata seed ISO)
if [[ "$TARGET" == "ubuntu-noble" ]]; then
  if ! command -v xorriso &>/dev/null; then
    echo "ERROR: 'xorriso' is not installed. Required for Ubuntu cidata ISO."
    echo "       Install with: sudo apt-get install -y xorriso"
    exit 1
  fi
fi

# AWS SSO session is valid
echo "==> Checking AWS SSO session..."
if ! aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" &>/dev/null; then
  echo "ERROR: AWS SSO session expired or not logged in."
  echo "       Run: aws sso login --profile $AWS_PROFILE"
  exit 1
fi

# Debian-specific preflight
HTTP_PID=""
HTTP_IP=""
if [[ "$TARGET" == "debian-trixie" ]]; then
  # WSL has a real LAN IP (mirrored networking)
  HTTP_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || true)
  if [[ -z "$HTTP_IP" || "$HTTP_IP" == 10.255.255.254 ]]; then
    echo "ERROR: Could not detect a valid LAN IP for the preseed HTTP server."
    echo "       WSL2 mirrored networking may not be enabled."
    echo "       Add 'networkingMode=mirrored' to C:\\Users\\<you>\\.wslconfig"
    echo "       Then run: wsl --shutdown"
    exit 1
  fi

  if [[ "$HTTP_IP" == 172.* ]]; then
    echo "ERROR: WSL IP is $HTTP_IP — this is a NAT address, not a LAN IP."
    echo "       Proxmox VMs cannot reach this address to fetch the preseed."
    echo "       Enable WSL2 mirrored networking (see README for instructions)."
    exit 1
  fi

  # Port not already in use
  if ss -tlnp | grep -q ":${PRESEED_PORT} "; then
    echo "ERROR: Port $PRESEED_PORT is already in use."
    echo "       Check for a previous build.sh process: ps aux | grep http.server"
    exit 1
  fi

  echo "==> Preflight checks passed. WSL LAN IP: $HTTP_IP"
else
  echo "==> Preflight checks passed."
fi

# ---------------------------------------------------------------------------
# Debian: start preseed HTTP server
# ---------------------------------------------------------------------------

if [[ "$TARGET" == "debian-trixie" ]]; then
  echo "==> Starting preseed HTTP server on ${HTTP_IP}:${PRESEED_PORT}..."
  python3 -m http.server "$PRESEED_PORT" \
    --directory "$SCRIPT_DIR/http/debian" \
    --bind "$HTTP_IP" > /dev/null 2>&1 &
  HTTP_PID=$!

  # Give it a moment to start then verify it's running
  sleep 1
  if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "ERROR: Failed to start preseed HTTP server."
    exit 1
  fi

  trap '
    echo "==> Stopping preseed HTTP server (PID '"$HTTP_PID"')..."
    kill "'"$HTTP_PID"'" 2>/dev/null || true
  ' EXIT
fi

# ---------------------------------------------------------------------------
# Fetch secrets from SSM
# ---------------------------------------------------------------------------

echo "==> Fetching secrets from AWS SSM..."

PACKER_TOKEN_SECRET=$(aws ssm get-parameter \
  --name "/infra/proxmox/packer_token" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION")

# ---------------------------------------------------------------------------
# Run Packer
# ---------------------------------------------------------------------------

echo "==> Starting Packer build: $TARGET"

cd "$BUILDS_DIR"

packer init .

EXTRA_VARS=()
if [[ "$TARGET" == "debian-trixie" ]]; then
  EXTRA_VARS+=(-var "preseed_url=http://${HTTP_IP}:${PRESEED_PORT}/preseed.cfg")
  EXTRA_VARS+=(-var "template_id=${DEBIAN_TEMPLATE_ID}")
elif [[ "$TARGET" == "ubuntu-noble" ]]; then
  EXTRA_VARS+=(-var "template_id=${UBUNTU_TEMPLATE_ID}")
fi

packer build \
  -var-file="$VARS_FILE" \
  -var "proxmox_token_secret=${PACKER_TOKEN_SECRET}" \
  "${EXTRA_VARS[@]}" \
  -only="${TARGET}.proxmox-iso.${TARGET}" \
  .

echo "==> Build complete: $TARGET"
