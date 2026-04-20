#!/bin/bash

# install docker 
sudo apt update -y 
sudo apt install -y docker.io docker-compose-v2 
sudo usermod -aG docker "${SUDO_USER:-$USER}"

# install aws cli
sudo apt install -y unzip
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

sudo reboot 
