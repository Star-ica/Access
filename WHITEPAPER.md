# Access Protocol — Whitepaper v1.0

**Onchain Membership and Access Management on BOT Chain**

---

## Abstract

Access is a decentralized membership protocol built on BOT Chain. Organizations register onchain, define membership plans with configurable pricing and durations, and issue passes to wallet addresses. Membership status is always verified by querying the contract directly — not by trusting a screenshot, a QR code, or a cached off-chain record. The protocol supports BOT native token and ERC-20 payments, invitation-only memberships, pass suspension and revocation, and pull-based revenue withdrawal for organizations.

---

## 1. The Problem with Membership Infrastructure

Most membership systems — even those used by Web3 communities — depend on centralized databases. This creates several failure modes:

- **Revocations are silent.** A deactivated account can still present a screenshot of an active membership.
- **Portability is absent.** Membership records belong to the platform, not the member.
- **Trust is implicit.** Anyone receiving a QR code must trust that the platform's database is live and accurate.
- **Integrations are fragile.** Each platform has its own API, auth model, and rate limits.

Access solves this by making the contract the single source of truth. Any application, smart contract, or access control system can call `isActiveMember(address, planId)` to check membership status in real time, permissionlessly.

---

## 2. Architecture

### 2.1 Participants

**Organizations** are registered onchain entities — DAOs, communities, protocols, event organizers, or online services. Each organization can create up to 20 membership plans and has an owner address that controls plan management and revenue withdrawal.

**Members** are wallet addresses that hold a membership pass issued by a plan. A pass is a struct stored in the contract, not a transferable NFT (passes are non-transferable by design).

**The Platform Administrator** manages platform-level controls: pausing the contract, deactivating malicious organizations, and withdrawing the 2% platform fee collected on each payment.

### 2.2 Contract Components

| Component | Function |
|-----------|----------|
| Organization Registry | Stores org metadata, owner address, and active status |
| Membership Plan Manager | Per-org plan definitions with pricing, duration, type, and capacity |
| Pass Registry | Individual membership records with live status |
| Invitation System | One-time invitation codes for invitation-only or free plans |
| Payment Processor | Handles BOT and ERC-20 payments with fee splitting |
| Withdrawal Manager | Pull-based revenue accumulation for orgs and treasury |

---

## 3. Membership Plans

Each plan defines:

| Field | Description |
|-------|-------------|
| Plan type | Paid, Free, or Invitation-only |
| Currency | BOT native or any ERC-20 token |
| Price | In smallest unit (wei for BOT) |
| Duration | Days until expiry (0 = lifetime) |
| Max members | Capacity cap (0 = unlimited) |
| Benefits | Human-readable description of what the plan includes |

### Plan types

**Paid:** Members pay the configured price on purchase. ERC-20 plans require the member to approve the contract before purchasing.

**Free:** Members can claim a pass with no payment. Useful for free-tier access or airdrop membership.

**Invitation-only:** Only wallets with a valid, unused invitation can claim a pass. The organization owner creates invitations per wallet address.

---

## 4. Membership Pass Lifecycle

```
Created (via purchase, free claim, or invitation)
    │
    ▼
 Active ──────────────────────────────────────────────────────────────────► Expired (time-based, automatic)
    │                                                                              │
    ├── suspend (org owner) ──► Suspended ──── unsuspend (org owner) ──► Active  │
    │                                                                              │
    └── revoke (org owner or admin) ──────────────────────────────────► Revoked  │
                                                                                   │
                                               renew (member) ◄────────────────────┘
```

**Key invariant:** Pass status is always checked live. The `getPassStatus(passId)` function re-evaluates expiry at read time — an expired pass is never returned as Active even if its stored status field says Active.

### Renewal

Members can renew an active or expired paid plan pass. Renewal extends the expiry from the current expiry (if still in the future) or from now (if already expired). Suspended or revoked passes cannot be renewed.

---

## 5. Payment and Revenue Model

### Fee structure

Each paid membership purchase and renewal pays a 2% platform fee. The remaining 98% accrues to the organization's withdrawable balance.

```
Member pays P
├── 2% → platform treasury (withdrawn by admin via withdrawTreasury)
└── 98% → org's withdrawable[orgId][token] balance
```

### Pull-based withdrawals

Neither the organization nor the platform receives funds automatically. Revenue accumulates in the contract and is withdrawn explicitly:
- `withdrawOrgRevenue(orgId, token)` — called by the org owner to claim their revenue
- `withdrawTreasury(token)` — called by the admin to claim platform fees

This pattern eliminates push-payment reentrancy risks and gives organizations flexibility over when to sweep funds.

### Multi-currency support

Each plan independently selects BOT native or any ERC-20 token. An organization can run a BOT-priced premium plan and a USDT-priced enterprise plan simultaneously. Revenue is tracked and withdrawn per token separately.

---

## 6. Verification

### Canonical membership check

```solidity
bool active = access.isActiveMember(holderAddress, planId);
```

This is the only authoritative check. It returns `true` only when:
- The holder has a pass for this plan
- The pass status is Active (not Suspended or Revoked)
- The pass has not expired (or is a lifetime pass)

### Organization-level check

```solidity
(bool active, uint256 planId) = access.isOrgMember(holderAddress, orgId);
```

Returns whether the holder is active in any plan belonging to the organization.

### Why not QR codes?

A QR code can encode a pass ID and holder address, and an application can scan it and call `isActiveMember` to verify. The QR code is a pointer to the contract state, not proof of membership itself. A screenshot of a QR code from an expired or revoked pass is worthless because the contract will return `false`. Access does not ship a QR renderer — the verification page is built into the dapp frontend, and any application can implement their own by calling the contract.

---

## 7. Security Considerations

| Risk | Mitigation |
|------|------------|
| Duplicate plan purchase | `_planHolderPass` mapping prevents the same wallet from purchasing the same plan twice |
| Overpayment (BOT) | Excess BOT above the plan price is refunded to the caller in the same transaction |
| ERC-20 reentrancy | Only trusted transfers; org and treasury balances tracked internally before any external call |
| Org owner key compromise | Organization ownership can be transferred via `transferOrgOwnership` |
| Admin key compromise | Two-step admin transfer; admin can pause the platform |
| Revenue stuck in contract | Pull withdrawal pattern; org owner always retains the right to withdraw their balance |
| Invitation replay | Invitations are single-use (`used` flag); each invite is for one specific wallet |
| Capacity overshoot | `currentMembers < maxMembers` check on purchase and invitation claim |
| Plan overshoot (org) | `MAX_PLANS = 20` per organization prevents unbounded storage growth |

**Known limitations:**
- The `withdrawTreasury` function iterates over all org IDs to calculate the treasury balance. This will become expensive at large org counts. A future version should track treasury balance as a running counter rather than computing it on withdrawal.
- There is no on-contract mechanism to verify the contents of `benefits` or `logoURI` fields. Organizations are responsible for the accuracy of their own plan descriptions.

---

## 8. Deployment

### Requirements
- Foundry (`forge`)
- BOT Chain RPC endpoint, deployer wallet, and treasury wallet address

### Steps

```bash
# 1. Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# 2. Set up project
forge init access-protocol && cd access-protocol
cp Access.sol src/
cp Deploy.s.sol script/

# 3. Deploy
BOT_CHAIN_RPC=https://your-rpc-url \
DEPLOYER_PRIVATE_KEY=0xyour-key \
TREASURY_ADDRESS=0xyour-treasury \
forge script script/Deploy.s.sol \
  --rpc-url $BOT_CHAIN_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast

# 4. Configure frontend
# Update CFG.CONTRACT_ADDRESS, CFG.CHAIN_ID, CFG.RPC_URL in index.html
```

### Post-deployment checklist
- [ ] Update `index.html` with deployed contract address and BOT Chain config
- [ ] Register your first organization via the dapp or directly via contract
- [ ] Create at least one membership plan
- [ ] Test a full purchase → verify → renew flow on a test wallet
- [ ] Verify `withdrawOrgRevenue` works correctly before publicizing

---

## 9. Use Cases

| Use case | Plan type | Notes |
|----------|-----------|-------|
| DAO membership | Paid / Free | Annual renewal; governance gating via `isActiveMember` |
| Hackathon participant | Invitation-only | Org owner issues one invitation per accepted team |
| Developer program | Paid (tiered) | Multiple plans (Basic, Pro, Enterprise) per org |
| Community Discord | Free | Unlimited free passes; bot checks contract for role assignment |
| Event access | Paid, capped | `maxMembers` set to venue capacity; lifetime pass (no expiry) |
| Newsletter subscription | Paid, recurring | Moderate duration; member renews to maintain access |

---

## 10. Glossary

| Term | Definition |
|------|-----------|
| Pass | Onchain membership record bound to a wallet address |
| Plan | A membership tier defined by an organization |
| Organization | An onchain entity that creates plans and issues passes |
| Invitation | A single-use, wallet-specific invitation to claim a pass |
| Active | A pass whose status is Active and has not expired |
| Lifetime | A pass with no expiry date (durationDays = 0) |
| Pull withdrawal | A pattern where funds accumulate in the contract and are claimed explicitly, not pushed automatically |

---

*Access Protocol v1.0 · Built on BOT Chain · Open source · MIT License*
