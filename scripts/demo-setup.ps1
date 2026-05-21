# Deploy full demo environment (Windows PowerShell)
# Prerequisites: Foundry installed, Anvil running on port 8545

$ErrorActionPreference = "Stop"
$contractsDir = Join-Path $PSScriptRoot "..\contracts"

Write-Host "==> Starting demo deployment..." -ForegroundColor Cyan
Push-Location $contractsDir

forge script script/DemoSetup.s.sol `
  --tc DemoSetupScript `
  --rpc-url http://127.0.0.1:8545 `
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 `
  --broadcast

Pop-Location

Write-Host ""
Write-Host "==> Demo environment ready." -ForegroundColor Green
Write-Host "    WETH:              0x5FbDB2315678afecb367f032d93F642f64180aa3"
Write-Host "    USDC:              0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
Write-Host "    GovernanceToken:   0x0165878A594ca255338adfa4d48449f69242Eb8F"
Write-Host "    LendingPool:       0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
Write-Host "    LiquidityMining:   0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
Write-Host "    Governance:        0x3Aa5ebB10DC797CAC828524e59A333d0A371443c"
