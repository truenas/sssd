#!/usr/bin/env bash

######################################################################
# Setup QEMU/libvirt on the GitHub Actions runner.
# (Adapted from the truenas_pylibzfs "QEMU VM Tests" workflow.)
######################################################################

set -eu

echo "Setting up QEMU environment..."

export DEBIAN_FRONTEND="noninteractive"
sudo apt-get -y update
sudo apt-get install -y \
  cloud-image-utils \
  guestfs-tools \
  virt-manager \
  qemu-system-x86 \
  qemu-utils \
  libvirt-daemon-system \
  libvirt-clients \
  rsync \
  wget

# Generate ssh keys for VM access
rm -f ~/.ssh/id_ed25519
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -q -N ""

# Free up resources
sudo systemctl stop docker.socket || true
sudo systemctl stop multipathd.socket || true

# Configure SSH client (no host-key prompts, short connect timeout)
mkdir -p "$HOME/.ssh"
cat <<EOF >> "$HOME/.ssh/config"
# No questions please
StrictHostKeyChecking no

# Small timeout for connection attempts
ConnectTimeout 10
EOF

# Ensure libvirt is running
sudo systemctl start libvirtd
sudo systemctl enable libvirtd
sudo usermod -a -G libvirt "$USER"

echo "QEMU setup complete"
