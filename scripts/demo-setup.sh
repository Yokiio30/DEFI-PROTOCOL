#!/bin/bash
# Deploy full demo environment (contracts + mock tokens + funded test accounts)
# Prerequisites: Foundry installed, Anvil running on port 8545

set -e

cd "$(dirname "$0")/../contracts"

echo "==> Starting demo deployment..."
forge script script/DemoSetup.s.sol \
  --tc DemoSetupScript \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast

echo ""
echo "==> Demo environment ready."
echo "    WETH:              0x5FbDB2315678afecb367f032d93F642f64180aa3"
echo "    USDC:              0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
echo "    GovernanceToken:   0x0165878A594ca255338adfa4d48449f69242Eb8F"
echo "    LendingPool:       0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
echo "    LiquidityMining:   0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
echo "    Governance:        0x3Aa5ebB10DC797CAC828524e59A333d0A371443c"
