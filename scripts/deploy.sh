#!/bin/bash
# Deploy all contracts to a local Anvil node
# Prerequisites: Foundry installed, Anvil running on port 8545

set -e

cd "$(dirname "$0")/../contracts"

echo "==> Deploying contracts to local Anvil..."
forge script script/Deploy.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast

echo "==> Deployment complete."
