#!/bin/bash

set -e

NEED_REBOOT=false

##### set timezone #####
sudo timedatectl set-timezone Asia/Kolkata

##### install docker and docker-compose #####
if ! command -v docker >/dev/null 2>&1; then
  sudo apt update -y
  sudo apt install -y docker.io docker-compose-v2
  sudo usermod -aG docker "${SUDO_USER:-$USER}"
  NEED_REBOOT=true
else
  echo "Docker already installed"
fi

#####  install aws cli #####
if ! command -v aws >/dev/null 2>&1; then
  sudo apt install -y unzip
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  sudo ./aws/install
  rm -rf aws awscliv2.zip
else
  echo "AWS CLI already installed"
fi

#####  reboot only if docker/compose installed #####
if [ "$NEED_REBOOT" = true ]; then
  echo "Reboot required — scheduling in background and exiting cleanly."
  nohup bash -c "sleep 5 && shutdown -r now" >/dev/null 2>&1 &
  exit 0
fi

echo "Setup complete. No reboot needed."
