import { useState, useEffect, useCallback } from "react";
import { ethers } from "ethers";
import LENDING_ABI from "../abis/LendingPool.json";

// Update with your deployed address
const LENDING_POOL_ADDRESS = import.meta.env.VITE_LENDING_POOL_ADDRESS || "0x0000000000000000000000000000000000000000";

const MOCK_ASSETS = [
  { symbol: "WETH", address: import.meta.env.VITE_WETH_ADDRESS || "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14", decimals: 18 },
  { symbol: "USDC", address: import.meta.env.VITE_USDC_ADDRESS || "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", decimals: 6 },
];

function fmt(val, decimals = 18, dp = 4) {
  if (!val) return "0.0000";
  try {
    return parseFloat(ethers.formatUnits(val, decimals)).toFixed(dp);
  } catch {
    return "0.0000";
  }
}

export default function LendingDashboard({ provider, signer, address }) {
  const [pool, setPool] = useState(null);
  const [selectedAsset, setSelectedAsset] = useState(MOCK_ASSETS[0]);
  const [depositAmount, setDepositAmount] = useState("");
  const [borrowAmount, setBorrowAmount] = useState("");
  const [userDeposit, setUserDeposit] = useState("0");
  const [userBorrow, setUserBorrow] = useState("0");
  const [healthFactor, setHealthFactor] = useState(null);
  const [borrowRate, setBorrowRate] = useState(null);
  const [depositRate, setDepositRate] = useState(null);
  const [allRates, setAllRates] = useState({});
  const [loading, setLoading] = useState(false);
  const [txStatus, setTxStatus] = useState(null);

  useEffect(() => {
    if (!provider) return;
    const contract = new ethers.Contract(LENDING_POOL_ADDRESS, LENDING_ABI, provider);
    setPool(contract);
  }, [provider]);

  const refresh = useCallback(async () => {
    if (!pool || !address) return;
    try {
      const asset = selectedAsset.address;
      const [dep, bor, hf, br, dr] = await Promise.all([
        pool.getDepositBalance(address, asset),
        pool.getBorrowBalance(address, asset),
        pool.healthFactor(address),
        pool.getBorrowRate(asset),
        pool.getDepositRate(asset),
      ]);
      setUserDeposit(dep.toString());
      setUserBorrow(bor.toString());
      setHealthFactor(hf);
      // Convert from Ray per-second to APY %
      const secondsPerYear = 31_536_000n;
      const RAY = 10n ** 27n;
      const borrowAPY = Number((br * secondsPerYear * 100n) / RAY);
      const depositAPY = Number((dr * secondsPerYear * 100n) / RAY);
      setBorrowRate(borrowAPY);
      setDepositRate(depositAPY);

      // Fetch rates for all assets for the Market Overview table
      const rates = {};
      await Promise.all(MOCK_ASSETS.map(async (a) => {
        const [aB, aD] = await Promise.all([
          pool.getBorrowRate(a.address),
          pool.getDepositRate(a.address),
        ]);
        rates[a.address] = {
          borrowRate: Number((aB * secondsPerYear * 100n) / RAY),
          depositRate: Number((aD * secondsPerYear * 100n) / RAY),
        };
      }));
      setAllRates(rates);
    } catch (err) {
      console.error("Refresh failed:", err);
    }
  }, [pool, address, selectedAsset]);

  useEffect(() => { refresh(); }, [refresh]);

  const getSignedPool = () => new ethers.Contract(LENDING_POOL_ADDRESS, LENDING_ABI, signer);

  const handleDeposit = async () => {
    if (!depositAmount || !signer) return;
    setLoading(true);
    setTxStatus("Approving...");
    try {
      const ERC20_ABI = ["function approve(address,uint256) returns (bool)"];
      const token = new ethers.Contract(selectedAsset.address, ERC20_ABI, signer);
      const amount = ethers.parseUnits(depositAmount, selectedAsset.decimals);
      const approveTx = await token.approve(LENDING_POOL_ADDRESS, amount);
      await approveTx.wait();
      setTxStatus("Depositing...");
      const tx = await getSignedPool().deposit(selectedAsset.address, amount);
      await tx.wait();
      setTxStatus("✓ Deposited successfully");
      setDepositAmount("");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 60)));
    } finally {
      setLoading(false);
      setTimeout(() => setTxStatus(null), 4000);
    }
  };

  const handleWithdraw = async () => {
    if (!signer) return;
    setLoading(true);
    setTxStatus("Withdrawing all...");
    try {
      const signedPool = getSignedPool();
      const shares = await signedPool.getDepositShares(address, selectedAsset.address);
      const tx = await signedPool.withdraw(selectedAsset.address, shares);
      await tx.wait();
      setTxStatus("✓ Withdrawn successfully");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 60)));
    } finally {
      setLoading(false);
      setTimeout(() => setTxStatus(null), 4000);
    }
  };

  const handleBorrow = async () => {
    if (!borrowAmount || !signer) return;
    setLoading(true);
    setTxStatus("Borrowing...");
    try {
      const amount = ethers.parseUnits(borrowAmount, selectedAsset.decimals);
      const tx = await getSignedPool().borrow(selectedAsset.address, amount);
      await tx.wait();
      setTxStatus("✓ Borrowed successfully");
      setBorrowAmount("");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 60)));
    } finally {
      setLoading(false);
      setTimeout(() => setTxStatus(null), 4000);
    }
  };

  const handleRepay = async () => {
    if (!signer) return;
    setLoading(true);
    setTxStatus("Repaying...");
    try {
      const signedPool = getSignedPool();
      const [borrowShares, borrowBalance] = await Promise.all([
        signedPool.getBorrowShares(address, selectedAsset.address),
        signedPool.getBorrowBalance(address, selectedAsset.address),
      ]);
      // Add 0.1% buffer for interest accruing before tx confirms
      const approveAmount = borrowBalance + borrowBalance / 1000n;
      const ERC20_ABI = ["function approve(address,uint256) returns (bool)"];
      const token = new ethers.Contract(selectedAsset.address, ERC20_ABI, signer);
      await (await token.approve(LENDING_POOL_ADDRESS, approveAmount)).wait();
      const tx = await signedPool.repay(selectedAsset.address, borrowShares);
      await tx.wait();
      setTxStatus("✓ Repaid successfully");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 60)));
    } finally {
      setLoading(false);
      setTimeout(() => setTxStatus(null), 4000);
    }
  };

  const hfDisplay = healthFactor
    ? healthFactor === BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
      ? "∞"
      : parseFloat(ethers.formatUnits(healthFactor, 18)).toFixed(2)
    : "—";

  const hfClass = !healthFactor ? ""
    : healthFactor === BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") ? "green"
    : parseFloat(ethers.formatUnits(healthFactor, 18)) >= 1.5 ? "green"
    : parseFloat(ethers.formatUnits(healthFactor, 18)) >= 1.0 ? "amber"
    : "red";

  return (
    <div>
      <p className="section-title">Lending Pool</p>

      {/* Stats */}
      <div className="stats-grid">
        <div className="stat">
          <div className="stat-label">Your Deposit</div>
          <div className="stat-value green">{fmt(userDeposit, selectedAsset.decimals)} {selectedAsset.symbol}</div>
        </div>
        <div className="stat">
          <div className="stat-label">Your Borrow</div>
          <div className="stat-value amber">{fmt(userBorrow, selectedAsset.decimals)} {selectedAsset.symbol}</div>
        </div>
        <div className="stat">
          <div className="stat-label">Health Factor</div>
          <div className={`stat-value ${hfClass}`}>{hfDisplay}</div>
        </div>
        <div className="stat">
          <div className="stat-label">Borrow APY</div>
          <div className="stat-value">{borrowRate !== null ? borrowRate.toFixed(2) + "%" : "—"}</div>
        </div>
        <div className="stat">
          <div className="stat-label">Deposit APY</div>
          <div className="stat-value green">{depositRate !== null ? depositRate.toFixed(2) + "%" : "—"}</div>
        </div>
      </div>

      {txStatus && <div className="notice">{txStatus}</div>}

      <div className="two-col">
        {/* Deposit / Withdraw */}
        <div className="card">
          <div className="card-title">Deposit & Withdraw</div>
          <div className="input-group">
            <label className="input-label">Asset</label>
            <select
              className="select"
              value={selectedAsset.address}
              onChange={(e) => setSelectedAsset(MOCK_ASSETS.find(a => a.address === e.target.value))}
            >
              {MOCK_ASSETS.map(a => (
                <option key={a.address} value={a.address}>{a.symbol}</option>
              ))}
            </select>
          </div>
          <div className="input-group">
            <label className="input-label">Amount</label>
            <input
              className="input"
              type="number"
              placeholder="0.00"
              value={depositAmount}
              onChange={e => setDepositAmount(e.target.value)}
            />
          </div>
          <div className="flex gap-12">
            <button className="btn btn-primary" onClick={handleDeposit} disabled={loading || !depositAmount}>
              Deposit
            </button>
            <button className="btn btn-ghost" onClick={handleWithdraw} disabled={loading || userDeposit === "0"}>
              Withdraw All
            </button>
          </div>
        </div>

        {/* Borrow / Repay */}
        <div className="card">
          <div className="card-title">Borrow & Repay</div>
          <div className="input-group">
            <label className="input-label">Collateral ratio at 75% max LTV</label>
            <div className="notice" style={{ marginBottom: 0 }}>
              Deposit first to use as collateral. Health factor must stay above 1.0.
            </div>
          </div>
          <div className="input-group mt-16">
            <label className="input-label">Borrow Amount</label>
            <input
              className="input"
              type="number"
              placeholder="0.00"
              value={borrowAmount}
              onChange={e => setBorrowAmount(e.target.value)}
            />
          </div>
          <div className="flex gap-12">
            <button className="btn btn-primary" onClick={handleBorrow} disabled={loading || !borrowAmount}>
              Borrow
            </button>
            <button className="btn btn-danger" onClick={handleRepay} disabled={loading || userBorrow === "0"}>
              Repay All
            </button>
          </div>
        </div>
      </div>

      {/* Market overview */}
      <div className="card mt-24">
        <div className="card-title">Market Overview</div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Asset</th>
                <th>Deposit APY</th>
                <th>Borrow APY</th>
                <th>Collateral Factor</th>
                <th>Liq. Threshold</th>
              </tr>
            </thead>
            <tbody>
              {MOCK_ASSETS.map(asset => {
                const r = allRates[asset.address];
                return (
                  <tr key={asset.address}>
                    <td><span className="mono">{asset.symbol}</span></td>
                    <td className="text-green">{r ? r.depositRate.toFixed(2) : "—"}%</td>
                    <td className="text-amber">{r ? r.borrowRate.toFixed(2) : "—"}%</td>
                    <td>75%</td>
                    <td>80%</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
