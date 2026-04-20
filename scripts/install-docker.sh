#!/bin/bash


set -euo pipefail

RUNNER_DIR="/home/ubuntu/actions-runner"

# Detect real user (works with sudo OR direct run)
RUNNER_USER="${SUDO_USER:-$USER}"

if command -v docker >/dev/null 2>&1; then
  echo "Docker is already installed: $(docker --version)"
else
  sudo apt update -y
  sudo apt install -y docker.io docker-compose-v2
  sudo usermod -aG docker "$RUNNER_USER" && newgrp docker
  echo "Docker installed."
fi

if [ -d "$RUNNER_DIR" ]; then
  cd "$RUNNER_DIR"
  sudo ./svc.sh stop || true
  sudo ./svc.sh start
fi

echo "######### Verifying installation #########"
docker --version
docker compose version
