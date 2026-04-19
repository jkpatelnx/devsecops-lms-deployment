#!/bin/bash

set -euo pipefail

# Detect real user (works with sudo OR direct run)
RUNNER_USER="${SUDO_USER:-$USER}"

if command -v docker >/dev/null 2>&1; then
  echo "Docker is already installed: $(docker --version)"
else
  sudo apt update -y
  sudo apt install -y docker.io docker-compose-v2
  echo "Docker installed."
fi

sudo usermod -aG docker "$RUNNER_USER"

echo "######### Verifying installation #########"
docker --version
docker compose version

sudo reboot 
