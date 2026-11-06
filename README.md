# Access — Onchain Membership Protocol

Decentralized membership and access management on BOT Chain.

## Files

| File | Description |
|------|-------------|
| `Access.sol` | Core contract — orgs, plans, passes, payments, verification |
| `Access.abi.json` | Contract ABI for frontend/integration use |
| `Deploy.s.sol` | Foundry deployment script |
| `index.html` | Complete frontend (single file, no build step) |
| `WHITEPAPER.md` | Full protocol documentation |

## Quick Start

### 1. Deploy

```bash
BOT_CHAIN_RPC=<rpc> DEPLOYER_PRIVATE_KEY=<key> TREASURY_ADDRESS=<addr> \
forge script Deploy.s.sol --rpc-url $BOT_CHAIN_RPC --private-key $DEPLOYER_PRIVATE_KEY --broadcast
```

### 2. Configure frontend

Update the `CFG` object at the top of the `<script>` section in `index.html`:

```js
const CFG = {
  CONTRACT_ADDRESS: "0x<deployed-address>",
  CHAIN_ID:   "0x<bot-chain-id-hex>",
  CHAIN_NAME: "BOT Chain",
  RPC_URL:    "https://<rpc>",
  EXPLORER:   "https://<explorer>"
};
```

### 3. Open in browser

No build step. Open `index.html` directly or deploy to any static host.

## User Flows

### Organization owner
Register org → Create plans (Paid / Free / Invite-only) → Manage members → Withdraw revenue

### Member
Browse directory → Purchase or claim pass → View passes → Renew before expiry

### Verifier
Call `isActiveMember(address, planId)` on the contract, or use the Verify tab in the frontend

## Key contract calls

```js
// Check membership (the canonical check — use this, not a screenshot)
const active = await contract.isActiveMember(holderAddress, planId);

// Purchase a paid plan (send BOT value equal to plan price)
await contract.purchaseMembership(planId, { value: price });

// Renew
await contract.renewMembership(passId, { value: price });
```

## Security notes

- Membership status is computed live at read time — expired passes are never shown as active
- All payments use pull-based withdrawal (no automatic pushes)
- ERC-20 purchases require an approve() call first
- Platform fee is 2% (200 bps); configurable only via contract redeployment
