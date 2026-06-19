#!/usr/bin/env bash
set -euo pipefail

if command -v gh >/dev/null 2>&1; then
  gh --version
  exit 0
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "ERROR: sudo is required to install gh on this runner" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update
sudo apt-get install -y ca-certificates curl jq
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

arch="$(dpkg --print-architecture)"
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

sudo apt-get update
sudo apt-get install -y gh
gh --version
