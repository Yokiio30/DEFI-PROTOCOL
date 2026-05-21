const CHAIN_NAMES = {
  1: "Mainnet",
  11155111: "Sepolia",
  31337: "Localhost",
};

export default function ConnectWallet({ address, chainId, onConnect }) {
  const short = address
    ? address.slice(0, 6) + "..." + address.slice(-4)
    : null;

  const chainName = chainId ? (CHAIN_NAMES[chainId] || `Chain ${chainId}`) : null;

  return address ? (
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      {chainName && (
        <span className="badge badge-purple" style={{ fontSize: 11 }}>{chainName}</span>
      )}
      <button className="wallet-btn">
        <span className="wallet-dot" />
        <span className="mono">{short}</span>
      </button>
    </div>
  ) : (
    <button className="wallet-btn" onClick={onConnect}>
      Connect Wallet
    </button>
  );
}
