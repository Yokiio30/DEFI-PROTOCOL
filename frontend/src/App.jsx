import { useState, useEffect, useCallback } from "react";
import { ethers } from "ethers";
import LendingDashboard from "./components/LendingDashboard";
import GovernanceDashboard from "./components/GovernanceDashboard";
import MiningDashboard from "./components/MiningDashboard";
import ConnectWallet from "./components/ConnectWallet";
import "./App.css";

export default function App() {
  const [provider, setProvider] = useState(null);
  const [signer, setSigner] = useState(null);
  const [address, setAddress] = useState(null);
  const [chainId, setChainId] = useState(null);
  const [activeTab, setActiveTab] = useState("lending");

  const connect = useCallback(async () => {
    if (!window.ethereum) {
      alert("Please install MetaMask");
      return;
    }
    try {
      const p = new ethers.BrowserProvider(window.ethereum);
      await p.send("eth_requestAccounts", []);
      const s = await p.getSigner();
      const addr = await s.getAddress();
      const net = await p.getNetwork();

      setProvider(p);
      setSigner(s);
      setAddress(addr);
      setChainId(Number(net.chainId));
    } catch (err) {
      console.error("Connection failed:", err);
    }
  }, []);

  useEffect(() => {
    if (!window.ethereum) return;

    window.ethereum.on("accountsChanged", (accounts) => {
      if (accounts.length === 0) {
        setAddress(null);
        setSigner(null);
      } else {
        connect();
      }
    });

    window.ethereum.on("chainChanged", () => {
      window.location.reload();
    });

    // Auto-connect if already authorized
    window.ethereum.request({ method: "eth_accounts" }).then((accounts) => {
      if (accounts.length > 0) connect();
    });

    return () => window.ethereum.removeAllListeners();
  }, [connect]);

  const tabs = [
    { id: "lending",    label: "Lending Pool",      icon: "⬡" },
    { id: "mining",     label: "Liquidity Mining",  icon: "⬢" },
    { id: "governance", label: "Governance",         icon: "⬣" },
  ];

  return (
    <div className="app">
      <header className="header">
        <div className="header-inner">
          <div className="logo">
            <span className="logo-mark">◈</span>
            <span className="logo-text">DeFi Protocol</span>
            <span className="logo-badge">v1.0</span>
          </div>
          <nav className="nav">
            {tabs.map((t) => (
              <button
                key={t.id}
                className={`nav-btn ${activeTab === t.id ? "active" : ""}`}
                onClick={() => setActiveTab(t.id)}
              >
                <span className="nav-icon">{t.icon}</span>
                {t.label}
              </button>
            ))}
          </nav>
          <ConnectWallet address={address} chainId={chainId} onConnect={connect} />
        </div>
      </header>

      <main className="main">
        {!address ? (
          <div className="landing">
            <div className="landing-glyph">◈</div>
            <h1>Upgradeable DeFi Protocol</h1>
            <p>Lending · Liquidity Mining · On-chain Governance</p>
            <button className="connect-cta" onClick={connect}>
              Connect Wallet to Start
            </button>
          </div>
        ) : (
          <div className="content">
            {activeTab === "lending" && (
              <LendingDashboard provider={provider} signer={signer} address={address} />
            )}
            {activeTab === "mining" && (
              <MiningDashboard provider={provider} signer={signer} address={address} />
            )}
            {activeTab === "governance" && (
              <GovernanceDashboard provider={provider} signer={signer} address={address} />
            )}
          </div>
        )}
      </main>
    </div>
  );
}
