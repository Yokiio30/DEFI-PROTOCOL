import { useState, useEffect, useCallback } from "react";
import { ethers } from "ethers";
import MINING_ABI from "../abis/LiquidityMining.json";

const MINING_ADDRESS = import.meta.env.VITE_MINING_ADDRESS || "0x0000000000000000000000000000000000000000";

export default function MiningDashboard({ provider, signer, address }) {
  const [mining, setMining] = useState(null);
  const [pools, setPools] = useState([]);
  const [stakeAmount, setStakeAmount] = useState("");
  const [selectedPool, setSelectedPool] = useState(0);
  const [loading, setLoading] = useState(false);
  const [txStatus, setTxStatus] = useState(null);

  useEffect(() => {
    if (!provider) return;
    const c = new ethers.Contract(MINING_ADDRESS, MINING_ABI, provider);
    setMining(c);
  }, [provider]);

  const refresh = useCallback(async () => {
    if (!mining || !address) return;
    try {
      const len = await mining.poolLength();
      const loaded = [];
      const DECIMALS_ABI = ["function decimals() view returns (uint8)"];
      for (let i = 0; i < Number(len); i++) {
        const [info, pending, userInfo] = await Promise.all([
          mining.poolInfo(i),
          mining.pendingReward(i, address),
          mining.userInfo(i, address),
        ]);
        let lpDecimals = 18;
        try {
          const lpContract = new ethers.Contract(info.lpToken, DECIMALS_ABI, provider);
          lpDecimals = await lpContract.decimals();
        } catch { /* use default 18 */ }
        loaded.push({ pid: i, lpToken: info.lpToken, allocPoint: info.allocPoint, totalStaked: info.totalStaked, pending, userStaked: userInfo.amount, lpDecimals: Number(lpDecimals) });
      }
      setPools(loaded);
    } catch (err) {
      console.error(err);
    }
  }, [mining, address]);

  useEffect(() => { refresh(); }, [refresh]);

  const getSignedMining = () => new ethers.Contract(MINING_ADDRESS, MINING_ABI, signer);

  const handleStake = async () => {
    if (!stakeAmount || !signer) return;
    setLoading(true); setTxStatus("Approving...");
    try {
      const pool = pools[selectedPool];
      if (!pool) return;
      const ERC20_ABI = ["function approve(address,uint256) returns (bool)"];
      const token = new ethers.Contract(pool.lpToken, ERC20_ABI, signer);
      const amount = ethers.parseUnits(stakeAmount, pool.lpDecimals ?? 18);
      await (await token.approve(MINING_ADDRESS, amount)).wait();
      setTxStatus("Staking...");
      const tx = await getSignedMining().stake(selectedPool, amount);
      await tx.wait();
      setTxStatus("✓ Staked");
      setStakeAmount("");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 60)));
    } finally { setLoading(false); setTimeout(() => setTxStatus(null), 4000); }
  };

  const handleUnstake = async (pid, amount) => {
    if (!signer) return;
    setLoading(true); setTxStatus("Unstaking...");
    try {
      const tx = await getSignedMining().unstake(pid, amount);
      await tx.wait();
      setTxStatus("✓ Unstaked");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 60)));
    } finally { setLoading(false); setTimeout(() => setTxStatus(null), 4000); }
  };

  const handleHarvest = async (pid) => {
    if (!signer) return;
    setLoading(true); setTxStatus("Harvesting...");
    try {
      const tx = await getSignedMining().harvest(pid, 0);
      await tx.wait();
      setTxStatus("✓ Harvested");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 60)));
    } finally { setLoading(false); setTimeout(() => setTxStatus(null), 4000); }
  };

  const fmt = (val, decimals = 18) => {
    try { return parseFloat(ethers.formatUnits(val, decimals)).toFixed(4); }
    catch { return "0.0000"; }
  };

  return (
    <div>
      <p className="section-title">Liquidity Mining</p>

      <div className="notice">
        Stake LP tokens or asset tokens to earn DPT governance token rewards.
        Rewards accrue per second based on your share of the pool.
      </div>

      {txStatus && <div className="notice mt-16">{txStatus}</div>}

      {/* Stake form */}
      <div className="card mt-24">
        <div className="card-title">Stake</div>
        <div className="input-group">
          <label className="input-label">Pool</label>
          <select className="select" value={selectedPool} onChange={e => setSelectedPool(Number(e.target.value))}>
            {pools.map(p => (
              <option key={p.pid} value={p.pid}>
                Pool #{p.pid} — alloc: {p.allocPoint?.toString() || "?"}
              </option>
            ))}
          </select>
        </div>
        <div className="input-group">
          <label className="input-label">Amount</label>
          <input className="input" type="number" placeholder="0.0" value={stakeAmount} onChange={e => setStakeAmount(e.target.value)} />
        </div>
        <button className="btn btn-primary" onClick={handleStake} disabled={loading || !stakeAmount || pools.length === 0}>
          Stake
        </button>
      </div>

      {/* Pool positions */}
      <div className="card mt-24">
        <div className="card-title">Your Positions</div>
        {pools.length === 0 ? (
          <p className="text-muted" style={{ fontSize: 14 }}>No pools configured yet.</p>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Pool</th>
                  <th>Staked</th>
                  <th>Pending Reward</th>
                  <th>Alloc Points</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {pools.map(p => (
                  <tr key={p.pid}>
                    <td><span className="mono">#{p.pid}</span></td>
                    <td>{fmt(p.userStaked, p.lpDecimals)} LP</td>
                    <td className="text-green">{fmt(p.pending)} DPT</td>
                    <td>{p.allocPoint?.toString() || "—"}</td>
                    <td>
                      <div className="flex gap-12">
                        <button className="btn btn-ghost btn-sm"
                          onClick={() => handleHarvest(p.pid)}
                          disabled={loading || p.pending === 0n}>
                          Harvest
                        </button>
                        <button className="btn btn-danger btn-sm"
                          onClick={() => handleUnstake(p.pid, p.userStaked)}
                          disabled={loading || p.userStaked === 0n}>
                          Unstake All
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
