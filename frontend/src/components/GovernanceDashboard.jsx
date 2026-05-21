import { useState, useEffect, useCallback } from "react";
import { ethers } from "ethers";
import GOV_ABI from "../abis/Governance.json";
import TOKEN_ABI from "../abis/GovernanceToken.json";

const GOV_ADDRESS   = import.meta.env.VITE_GOVERNANCE_ADDRESS   || "0x0000000000000000000000000000000000000000";
const TOKEN_ADDRESS = import.meta.env.VITE_GOV_TOKEN_ADDRESS || "0x0000000000000000000000000000000000000000";

const STATE_LABELS = ["Pending","Active","Defeated","Succeeded","Queued","Executed","Cancelled","Expired"];
const STATE_BADGES = ["badge-gray","badge-purple","badge-red","badge-green","badge-amber","badge-green","badge-gray","badge-red"];

export default function GovernanceDashboard({ provider, signer, address }) {
  const [gov, setGov] = useState(null);
  const [proposals, setProposals] = useState([]);
  const [tokenBalance, setTokenBalance] = useState("0");
  const [proposalCount, setProposalCount] = useState(0);
  const [loading, setLoading] = useState(false);
  const [txStatus, setTxStatus] = useState(null);
  const [activeProposalId, setActiveProposalId] = useState(null);
  const [voteChoices, setVoteChoices] = useState({}); // { [proposalId]: 0|1|2 }

  // New proposal form
  const [newDesc, setNewDesc] = useState("");
  const [newTarget, setNewTarget] = useState("");
  const [newCalldata, setNewCalldata] = useState("0x");

  useEffect(() => {
    if (!provider) return;
    const contract = new ethers.Contract(GOV_ADDRESS, GOV_ABI, provider);
    setGov(contract);
  }, [provider]);

  const refresh = useCallback(async () => {
    if (!gov || !address) return;
    try {
      const token = new ethers.Contract(TOKEN_ADDRESS, TOKEN_ABI, provider);
      const [bal, count] = await Promise.all([
        token.balanceOf(address),
        gov.proposalCount(),
      ]);
      setTokenBalance(bal.toString());
      setProposalCount(Number(count));

      const loaded = [];
      const total = Number(count);
      const start = Math.max(1, total - 9); // load last 10
      for (let i = start; i <= total; i++) {
        try {
          const [p, s] = await Promise.all([gov.getProposal(i), gov.state(i)]);
          loaded.push({
            id: p.id, proposer: p.proposer, targets: p.targets,
            values: p.values, calldatas: p.calldatas, description: p.description,
            startTime: p.startTime, endTime: p.endTime, eta: p.eta,
            forVotes: p.forVotes, againstVotes: p.againstVotes, abstainVotes: p.abstainVotes,
            executed: p.executed, cancelled: p.cancelled, state: Number(s)
          });
        } catch {}
      }
      setProposals(loaded.reverse());
    } catch (err) {
      console.error(err);
    }
  }, [gov, address, provider]);

  useEffect(() => { refresh(); }, [refresh]);

  const getSignedGov = () => new ethers.Contract(GOV_ADDRESS, GOV_ABI, signer);

  const handlePropose = async () => {
    if (!newDesc || !newTarget || !signer) return;
    setLoading(true); setTxStatus("Submitting proposal...");
    try {
      const tx = await getSignedGov().propose(
        [newTarget], [0], [newCalldata || "0x"], newDesc
      );
      await tx.wait();
      setTxStatus("✓ Proposal created");
      setNewDesc(""); setNewTarget(""); setNewCalldata("0x");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 80)));
    } finally {
      setLoading(false);
      setTimeout(() => setTxStatus(null), 5000);
    }
  };

  const handleVote = async (pid) => {
    if (!signer) return;
    setLoading(true); setTxStatus("Casting vote...");
    try {
      const choice = voteChoices[pid.toString()] ?? 1;
      const tx = await getSignedGov().castVote(pid, choice);
      await tx.wait();
      setTxStatus("✓ Vote cast");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 80)));
    } finally {
      setLoading(false);
      setTimeout(() => setTxStatus(null), 4000);
    }
  };

  const handleQueue = async (pid) => {
    setLoading(true); setTxStatus("Queueing...");
    try {
      const tx = await getSignedGov().queue(pid);
      await tx.wait();
      setTxStatus("✓ Queued");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 80)));
    } finally { setLoading(false); setTimeout(() => setTxStatus(null), 4000); }
  };

  const handleExecute = async (pid) => {
    setLoading(true); setTxStatus("Executing...");
    try {
      const tx = await getSignedGov().execute(pid, { value: 0 });
      await tx.wait();
      setTxStatus("✓ Executed");
      await refresh();
    } catch (err) {
      setTxStatus("✗ " + (err.reason || err.message?.slice(0, 80)));
    } finally { setLoading(false); setTimeout(() => setTxStatus(null), 4000); }
  };

  const fmtTokens = (raw) => {
    try { return parseFloat(ethers.formatEther(raw)).toLocaleString(undefined, { maximumFractionDigits: 0 }); }
    catch { return "0"; }
  };

  const fmtTime = (ts) => {
    if (!ts || ts === 0n) return "—";
    const d = new Date(Number(ts) * 1000);
    return d.toLocaleDateString() + " " + d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  };

  const totalVotes = (p) => {
    try {
      const f = BigInt(p.forVotes.toString());
      const a = BigInt(p.againstVotes.toString());
      const ab = BigInt(p.abstainVotes.toString());
      return f + a + ab;
    } catch { return 0n; }
  };

  const votePercent = (votes, total) => {
    if (!total || total === 0n) return 0;
    return Number((BigInt(votes.toString()) * 100n) / total);
  };

  return (
    <div>
      <p className="section-title">Governance</p>

      <div className="stats-grid">
        <div className="stat">
          <div className="stat-label">Your Voting Power</div>
          <div className="stat-value green">{fmtTokens(tokenBalance)} DPT</div>
        </div>
        <div className="stat">
          <div className="stat-label">Total Proposals</div>
          <div className="stat-value">{proposalCount}</div>
        </div>
        <div className="stat">
          <div className="stat-label">Active Now</div>
          <div className="stat-value amber">
            {proposals.filter(p => p.state === 1).length}
          </div>
        </div>
      </div>

      {txStatus && <div className="notice">{txStatus}</div>}

      {/* Create proposal */}
      <div className="card mt-24">
        <div className="card-title">Create Proposal</div>
        <div className="notice">
          You need ≥ 1,000 DPT to submit a proposal. Proposals enter a 1-hour voting delay before voting opens.
        </div>
        <div className="input-group mt-16">
          <label className="input-label">Description</label>
          <input className="input" placeholder="Proposal title and motivation..." value={newDesc} onChange={e => setNewDesc(e.target.value)} />
        </div>
        <div className="input-group">
          <label className="input-label">Target Contract Address</label>
          <input className="input mono" placeholder="0x..." value={newTarget} onChange={e => setNewTarget(e.target.value)} />
        </div>
        <div className="input-group">
          <label className="input-label">Calldata (ABI-encoded)</label>
          <input className="input mono" placeholder="0x" value={newCalldata} onChange={e => setNewCalldata(e.target.value)} />
        </div>
        <button className="btn btn-primary" onClick={handlePropose} disabled={loading || !newDesc || !newTarget}>
          Submit Proposal
        </button>
      </div>

      {/* Proposals list */}
      <div className="card mt-24">
        <div className="card-title">Recent Proposals</div>
        {proposals.length === 0 ? (
          <p className="text-muted" style={{ fontSize: 14 }}>No proposals yet.</p>
        ) : proposals.map(p => {
          const total = totalVotes(p);
          const forPct = votePercent(p.forVotes, total);
          const againstPct = votePercent(p.againstVotes, total);
          const isActive = p.state === 1;
          const isSucceeded = p.state === 3;
          const isQueued = p.state === 4;

          return (
            <div key={p.id.toString()} style={{ marginBottom: 20, paddingBottom: 20, borderBottom: "1px solid var(--border)" }}>
              <div className="flex items-center justify-between" style={{ marginBottom: 8 }}>
                <span className="mono" style={{ color: "var(--text3)", fontSize: 12 }}>#{p.id.toString()}</span>
                <span className={`badge ${STATE_BADGES[p.state]}`}>{STATE_LABELS[p.state]}</span>
              </div>
              <p style={{ fontWeight: 500, marginBottom: 8 }}>{p.description || "—"}</p>
              <p style={{ fontSize: 12, color: "var(--text3)", marginBottom: 12 }}>
                Voting: {fmtTime(p.startTime)} → {fmtTime(p.endTime)}
              </p>

              {/* Vote bars */}
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 12 }}>
                <div>
                  <div className="flex justify-between" style={{ fontSize: 11, color: "var(--text3)", marginBottom: 4 }}>
                    <span>FOR</span><span>{fmtTokens(p.forVotes)} ({forPct}%)</span>
                  </div>
                  <div className="progress-bar">
                    <div className="progress-fill green" style={{ width: forPct + "%" }} />
                  </div>
                </div>
                <div>
                  <div className="flex justify-between" style={{ fontSize: 11, color: "var(--text3)", marginBottom: 4 }}>
                    <span>AGAINST</span><span>{fmtTokens(p.againstVotes)} ({againstPct}%)</span>
                  </div>
                  <div className="progress-bar">
                    <div className="progress-fill" style={{ width: againstPct + "%", background: "var(--red)" }} />
                  </div>
                </div>
              </div>

              {/* Actions */}
              <div className="flex gap-12">
                {isActive && (
                  <div className="flex gap-12 items-center">
                    <select className="select" style={{ width: "auto", padding: "6px 12px" }}
                      value={voteChoices[p.id.toString()] ?? 1}
                      onChange={e => setVoteChoices(prev => ({ ...prev, [p.id.toString()]: Number(e.target.value) }))}>
                      <option value={1}>For</option>
                      <option value={0}>Against</option>
                      <option value={2}>Abstain</option>
                    </select>
                    <button className="btn btn-primary btn-sm" onClick={() => handleVote(p.id)} disabled={loading}>
                      Cast Vote
                    </button>
                  </div>
                )}
                {isSucceeded && (
                  <button className="btn btn-ghost btn-sm" onClick={() => handleQueue(p.id)} disabled={loading}>
                    Queue
                  </button>
                )}
                {isQueued && (
                  <button className="btn btn-primary btn-sm" onClick={() => handleExecute(p.id)} disabled={loading}>
                    Execute
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
