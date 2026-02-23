#!/bin/bash
set -e #Exit on Error

if [ "$EUID" -ne 0 ]; then
	echo "Run this script as root"
	exit 1
fi 
# Checks if you are running as root

# See: https://docs.docker.com/engine/install/ubuntu/

# Remove other/old versions of docker
dpkg --remove docker docker-engine docker.io containerd runc || true

apt install --assume-yes ca-certificates curl gnupg lsb-release
mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

chmod a+r /etc/apt/keyrings/docker.gpg
apt update

apt install --assume-yes git jq xdg-utils docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
# jq is sed but for json data, xdg-utils is a list of scrpts that help command line tools to talk to ur DeskTop environment
usermod --append --groups docker "$SUDO_USER"

systemctl enable --now docker

echo 'Reboot your OS!'
