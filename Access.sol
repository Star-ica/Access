// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Access — Onchain Membership and Access Management
 * @notice Organizations create membership plans; members purchase/claim passes.
 *         Membership status is always checked live from contract state.
 * @dev Supports BOT native token and any ERC-20 (e.g. USDT on BOT Chain).
 *      Uses pull-based withdrawals to prevent reentrancy issues.
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Access {

    // ── Constants ─────────────────────────────────────────────────────────
    uint256 public constant PLATFORM_FEE_BPS = 200; // 2% platform fee (basis points)
    uint256 public constant BPS_DENOM        = 10000;
    uint256 public constant MAX_PLANS        = 20;   // per organization

    // ── Enums ─────────────────────────────────────────────────────────────
    enum PassStatus { Active, Expired, Suspended, Revoked }
    enum PlanType   { Paid, Free, InvitationOnly }
    enum Currency   { BOT, ERC20 }

    // ── Structs ───────────────────────────────────────────────────────────
    struct Organization {
        string   name;
        string   description;
        string   logoURI;
        string   websiteURL;
        address  owner;
        bool     exists;
        bool     active;
        uint40   createdAt;
        uint256  totalRevenue;   // in smallest unit of their chosen currency
    }

    struct MembershipPlan {
        uint256  orgId;
        string   name;
        string   description;
        string   benefits;       // comma-separated or JSON string of benefits
        PlanType planType;
        Currency currency;
        address  tokenAddress;   // address(0) for BOT native
        uint256  price;          // 0 for free plans
        uint32   durationDays;   // 0 = lifetime
        uint32   maxMembers;     // 0 = unlimited
        uint32   currentMembers;
        bool     active;
        uint40   createdAt;
    }

    struct MembershipPass {
        uint256    orgId;
        uint256    planId;
        address    holder;
        PassStatus status;
        uint40     issuedAt;
        uint40     expiresAt;    // 0 = lifetime
        uint40     suspendedAt;
        uint40     revokedAt;
        string     revokeReason;
        bool       isInvitation; // true if invitation-only or free claim
    }

    struct PendingInvitation {
        uint256 planId;
        address invitee;
        uint40  createdAt;
        bool    used;
    }

    // ── State ─────────────────────────────────────────────────────────────
    address public admin;
    address public pendingAdmin;
    address public treasury;     // receives platform fees
    bool    public paused;

    uint256 public orgCount;
    uint256 public planCount;
    uint256 public passCount;
    uint256 public inviteCount;

    mapping(uint256 => Organization)        public orgs;
    mapping(uint256 => MembershipPlan)      public plans;
    mapping(uint256 => MembershipPass)      public passes;
    mapping(uint256 => PendingInvitation)   public invitations;

    // owner address → list of org IDs they own
    mapping(address => uint256[])           public ownerOrgs;
    // org ID → list of plan IDs
    mapping(uint256 => uint256[])           public orgPlans;
    // org ID → list of pass IDs (all members ever)
    mapping(uint256 => uint256[])           public orgPasses;
    // holder address → list of pass IDs they hold
    mapping(address => uint256[])           public holderPasses;
    // plan ID → list of invitation IDs
    mapping(uint256 => uint256[])           public planInvitations;
    // plan ID → holder address → pass ID (+1, 0 means no pass)
    mapping(uint256 => mapping(address => uint256)) private _planHolderPass;

    // pull-based withdrawal balances per org per token (address(0) = BOT)
    mapping(uint256 => mapping(address => uint256)) public orgWithdrawable;

    // ── Events ────────────────────────────────────────────────────────────
    event OrgRegistered(uint256 indexed orgId, address indexed owner, string name);
    event OrgUpdated(uint256 indexed orgId);
    event PlanCreated(uint256 indexed planId, uint256 indexed orgId, string name);
    event PlanUpdated(uint256 indexed planId);
    event PlanDeactivated(uint256 indexed planId);
    event PassIssued(uint256 indexed passId, uint256 indexed planId, address indexed holder);
    event PassRenewed(uint256 indexed passId, uint40 newExpiry);
    event PassSuspended(uint256 indexed passId);
    event PassUnsuspended(uint256 indexed passId);
    event PassRevoked(uint256 indexed passId, string reason);
    event InvitationCreated(uint256 indexed inviteId, uint256 indexed planId, address invitee);
    event InvitationUsed(uint256 indexed inviteId, uint256 passId);
    event OrgWithdrawal(uint256 indexed orgId, address token, uint256 amount);
    event TreasuryWithdrawal(address token, uint256 amount);
    event AdminTransferInitiated(address newAdmin);
    event AdminTransferred(address oldAdmin, address newAdmin);
    event Paused(bool state);

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier onlyAdmin() {
        require(msg.sender == admin, "Access: not admin");
        _;
    }

    modifier onlyOrgOwner(uint256 orgId) {
        require(orgs[orgId].exists, "Access: org not found");
        require(orgs[orgId].owner == msg.sender, "Access: not org owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Access: paused");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(address _treasury) {
        require(_treasury != address(0), "Access: zero treasury");
        admin    = msg.sender;
        treasury = _treasury;
    }

    // ─────────────────────────────────────────────────────────────────────
    // ORGANIZATION MANAGEMENT
    // ─────────────────────────────────────────────────────────────────────

    function registerOrg(
        string calldata name,
        string calldata description,
        string calldata logoURI,
        string calldata websiteURL
    ) external whenNotPaused returns (uint256 orgId) {
        require(bytes(name).length > 0 && bytes(name).length <= 80, "Access: invalid name");
        orgId = ++orgCount;
        orgs[orgId] = Organization({
            name:         name,
            description:  description,
            logoURI:      logoURI,
            websiteURL:   websiteURL,
            owner:        msg.sender,
            exists:       true,
            active:       true,
            createdAt:    uint40(block.timestamp),
            totalRevenue: 0
        });
        ownerOrgs[msg.sender].push(orgId);
        emit OrgRegistered(orgId, msg.sender, name);
    }

    function updateOrg(
        uint256 orgId,
        string calldata name,
        string calldata description,
        string calldata logoURI,
        string calldata websiteURL
    ) external onlyOrgOwner(orgId) {
        require(bytes(name).length > 0 && bytes(name).length <= 80, "Access: invalid name");
        Organization storage o = orgs[orgId];
        o.name        = name;
        o.description = description;
        o.logoURI     = logoURI;
        o.websiteURL  = websiteURL;
        emit OrgUpdated(orgId);
    }

    function transferOrgOwnership(uint256 orgId, address newOwner) external onlyOrgOwner(orgId) {
        require(newOwner != address(0), "Access: zero address");
        orgs[orgId].owner = newOwner;
        ownerOrgs[newOwner].push(orgId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // MEMBERSHIP PLAN MANAGEMENT
    // ─────────────────────────────────────────────────────────────────────

    function createPlan(
        uint256        orgId,
        string calldata name,
        string calldata description,
        string calldata benefits,
        PlanType       planType,
        Currency       currency,
        address        tokenAddress,
        uint256        price,
        uint32         durationDays,
        uint32         maxMembers
    ) external onlyOrgOwner(orgId) whenNotPaused returns (uint256 planId) {
        require(orgPlans[orgId].length < MAX_PLANS, "Access: too many plans");
        require(bytes(name).length > 0, "Access: plan name required");
        if (planType == PlanType.Paid) {
            require(price > 0, "Access: paid plan needs price");
        }
        if (currency == Currency.ERC20) {
            require(tokenAddress != address(0), "Access: ERC20 needs token address");
        }

        planId = ++planCount;
        plans[planId] = MembershipPlan({
            orgId:          orgId,
            name:           name,
            description:    description,
            benefits:       benefits,
            planType:       planType,
            currency:       currency,
            tokenAddress:   tokenAddress,
            price:          price,
            durationDays:   durationDays,
            maxMembers:     maxMembers,
            currentMembers: 0,
            active:         true,
            createdAt:      uint40(block.timestamp)
        });
        orgPlans[orgId].push(planId);
        emit PlanCreated(planId, orgId, name);
    }

    function updatePlan(
        uint256        planId,
        string calldata name,
        string calldata description,
        string calldata benefits,
        uint256        price,
        uint32         durationDays,
        uint32         maxMembers
    ) external whenNotPaused {
        MembershipPlan storage p = plans[planId];
        require(p.active, "Access: plan inactive");
        require(orgs[p.orgId].owner == msg.sender, "Access: not org owner");
        p.name         = name;
        p.description  = description;
        p.benefits     = benefits;
        p.price        = price;
        p.durationDays = durationDays;
        p.maxMembers   = maxMembers;
        emit PlanUpdated(planId);
    }

    function deactivatePlan(uint256 planId) external {
        MembershipPlan storage p = plans[planId];
        require(orgs[p.orgId].owner == msg.sender || msg.sender == admin, "Access: unauthorized");
        p.active = false;
        emit PlanDeactivated(planId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // MEMBERSHIP PURCHASE / CLAIM
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Purchase a paid membership or claim a free one.
     *         For ERC20 plans, caller must approve this contract first.
     */
    function purchaseMembership(uint256 planId) external payable whenNotPaused returns (uint256 passId) {
        MembershipPlan storage plan = plans[planId];
        require(plan.active, "Access: plan inactive");
        require(orgs[plan.orgId].active, "Access: org inactive");
        require(plan.planType != PlanType.InvitationOnly, "Access: invitation only");
        require(
            plan.maxMembers == 0 || plan.currentMembers < plan.maxMembers,
            "Access: plan full"
        );
        require(
            _planHolderPass[planId][msg.sender] == 0,
            "Access: already a member of this plan"
        );

        uint256 fee = 0;
        if (plan.planType == PlanType.Paid && plan.price > 0) {
            fee = (plan.price * PLATFORM_FEE_BPS) / BPS_DENOM;
            uint256 orgAmount = plan.price - fee;

            if (plan.currency == Currency.BOT) {
                require(msg.value >= plan.price, "Access: insufficient BOT sent");
                orgWithdrawable[plan.orgId][address(0)] += orgAmount;
                // return excess
                if (msg.value > plan.price) {
                    (bool ok,) = msg.sender.call{value: msg.value - plan.price}("");
                    require(ok, "Access: refund failed");
                }
            } else {
                require(msg.value == 0, "Access: send no BOT for ERC20 plan");
                bool ok = IERC20(plan.tokenAddress).transferFrom(msg.sender, address(this), plan.price);
                require(ok, "Access: token transfer failed");
                orgWithdrawable[plan.orgId][plan.tokenAddress] += orgAmount;
            }

            orgs[plan.orgId].totalRevenue += plan.price;
        } else {
            require(msg.value == 0, "Access: free plan, send no BOT");
        }

        passId = _mintPass(planId, plan, msg.sender, false);
    }

    // ─────────────────────────────────────────────────────────────────────
    // INVITATION SYSTEM
    // ─────────────────────────────────────────────────────────────────────

    function createInvitation(uint256 planId, address invitee)
        external whenNotPaused returns (uint256 inviteId)
    {
        MembershipPlan storage plan = plans[planId];
        require(plan.active, "Access: plan inactive");
        require(orgs[plan.orgId].owner == msg.sender, "Access: not org owner");
        require(plan.planType == PlanType.InvitationOnly || plan.planType == PlanType.Free, "Access: not invite plan");
        require(_planHolderPass[planId][invitee] == 0, "Access: already a member");

        inviteId = ++inviteCount;
        invitations[inviteId] = PendingInvitation({
            planId:    planId,
            invitee:   invitee,
            createdAt: uint40(block.timestamp),
            used:      false
        });
        planInvitations[planId].push(inviteId);
        emit InvitationCreated(inviteId, planId, invitee);
    }

    function claimInvitation(uint256 inviteId) external whenNotPaused returns (uint256 passId) {
        PendingInvitation storage inv = invitations[inviteId];
        require(!inv.used, "Access: invitation already used");
        require(inv.invitee == msg.sender, "Access: not your invitation");

        MembershipPlan storage plan = plans[inv.planId];
        require(plan.active, "Access: plan inactive");
        require(
            plan.maxMembers == 0 || plan.currentMembers < plan.maxMembers,
            "Access: plan full"
        );

        inv.used = true;
        passId   = _mintPass(inv.planId, plan, msg.sender, true);
        emit InvitationUsed(inviteId, passId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // PASS RENEWAL
    // ─────────────────────────────────────────────────────────────────────

    function renewMembership(uint256 passId) external payable whenNotPaused {
        MembershipPass storage pass = passes[passId];
        require(pass.holder == msg.sender, "Access: not pass holder");
        require(pass.status != PassStatus.Revoked, "Access: pass revoked");
        require(pass.status != PassStatus.Suspended, "Access: pass suspended");

        MembershipPlan storage plan = plans[pass.planId];
        require(plan.active, "Access: plan inactive");
        require(plan.durationDays > 0, "Access: lifetime pass, no renewal needed");
        require(plan.planType == PlanType.Paid, "Access: only paid plans renew");

        uint256 fee      = (plan.price * PLATFORM_FEE_BPS) / BPS_DENOM;
        uint256 orgAmount = plan.price - fee;

        if (plan.currency == Currency.BOT) {
            require(msg.value >= plan.price, "Access: insufficient BOT");
            orgWithdrawable[plan.orgId][address(0)] += orgAmount;
            if (msg.value > plan.price) {
                (bool ok,) = msg.sender.call{value: msg.value - plan.price}("");
                require(ok, "Access: refund failed");
            }
        } else {
            require(msg.value == 0, "Access: ERC20 plan");
            bool ok = IERC20(plan.tokenAddress).transferFrom(msg.sender, address(this), plan.price);
            require(ok, "Access: token transfer failed");
            orgWithdrawable[plan.orgId][plan.tokenAddress] += orgAmount;
        }

        orgs[plan.orgId].totalRevenue += plan.price;

        // Extend from current expiry (or now if already expired)
        uint40 base = pass.expiresAt > uint40(block.timestamp) ? pass.expiresAt : uint40(block.timestamp);
        pass.expiresAt = base + uint40(plan.durationDays) * 1 days;
        pass.status    = PassStatus.Active;

        emit PassRenewed(passId, pass.expiresAt);
    }

    // ─────────────────────────────────────────────────────────────────────
    // PASS MANAGEMENT (org owner)
    // ─────────────────────────────────────────────────────────────────────

    function suspendPass(uint256 passId) external {
        _requireOrgOwnerForPass(passId);
        require(passes[passId].status == PassStatus.Active, "Access: not active");
        passes[passId].status      = PassStatus.Suspended;
        passes[passId].suspendedAt = uint40(block.timestamp);
        emit PassSuspended(passId);
    }

    function unsuspendPass(uint256 passId) external {
        _requireOrgOwnerForPass(passId);
        require(passes[passId].status == PassStatus.Suspended, "Access: not suspended");
        passes[passId].status = PassStatus.Active;
        emit PassUnsuspended(passId);
    }

    function revokePass(uint256 passId, string calldata reason) external {
        _requireOrgOwnerForPass(passId);
        require(passes[passId].status != PassStatus.Revoked, "Access: already revoked");
        PassStatus prev = passes[passId].status;
        passes[passId].status      = PassStatus.Revoked;
        passes[passId].revokedAt   = uint40(block.timestamp);
        passes[passId].revokeReason = reason;
        if (prev == PassStatus.Active) {
            plans[passes[passId].planId].currentMembers--;
        }
        emit PassRevoked(passId, reason);
    }

    // Admin can also revoke
    function adminRevokePass(uint256 passId, string calldata reason) external onlyAdmin {
        require(passes[passId].status != PassStatus.Revoked, "Access: already revoked");
        PassStatus prev = passes[passId].status;
        passes[passId].status       = PassStatus.Revoked;
        passes[passId].revokedAt    = uint40(block.timestamp);
        passes[passId].revokeReason = reason;
        if (prev == PassStatus.Active) {
            plans[passes[passId].planId].currentMembers--;
        }
        emit PassRevoked(passId, reason);
    }

    // ─────────────────────────────────────────────────────────────────────
    // WITHDRAWALS (pull pattern)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Org owner withdraws their accumulated revenue.
     * @param token address(0) for BOT, ERC20 token address otherwise.
     */
    function withdrawOrgRevenue(uint256 orgId, address token) external onlyOrgOwner(orgId) {
        uint256 amount = orgWithdrawable[orgId][token];
        require(amount > 0, "Access: nothing to withdraw");
        orgWithdrawable[orgId][token] = 0;

        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "Access: BOT transfer failed");
        } else {
            bool ok = IERC20(token).transfer(msg.sender, amount);
            require(ok, "Access: token transfer failed");
        }
        emit OrgWithdrawal(orgId, token, amount);
    }

    /**
     * @notice Platform admin withdraws accumulated platform fees.
     */
    function withdrawTreasury(address token) external onlyAdmin {
        uint256 amount;
        if (token == address(0)) {
            // Calculate treasury balance = contract balance - all org withdrawable BOT
            uint256 orgTotal;
            for (uint256 i = 1; i <= orgCount; i++) {
                orgTotal += orgWithdrawable[i][address(0)];
            }
            amount = address(this).balance - orgTotal;
        } else {
            uint256 orgTotal;
            for (uint256 i = 1; i <= orgCount; i++) {
                orgTotal += orgWithdrawable[i][token];
            }
            amount = IERC20(token).balanceOf(address(this)) - orgTotal;
        }
        require(amount > 0, "Access: no fees");

        if (token == address(0)) {
            (bool ok,) = treasury.call{value: amount}("");
            require(ok, "Access: BOT transfer failed");
        } else {
            bool ok = IERC20(token).transfer(treasury, amount);
            require(ok, "Access: token transfer failed");
        }
        emit TreasuryWithdrawal(token, amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // VERIFICATION
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Check if an address holds an active, non-expired membership in a plan.
     *         This is the canonical membership status check — do not rely on screenshots.
     */
    function isActiveMember(address holder, uint256 planId) external view returns (bool) {
        uint256 rawId = _planHolderPass[planId][holder];
        if (rawId == 0) return false;
        uint256 passId = rawId - 1;
        MembershipPass storage pass = passes[passId];
        if (pass.status != PassStatus.Active) return false;
        if (pass.expiresAt != 0 && pass.expiresAt < block.timestamp) return false;
        return true;
    }

    /**
     * @notice Check membership in any plan of an org.
     */
    function isOrgMember(address holder, uint256 orgId) external view returns (bool active, uint256 activePlanId) {
        uint256[] storage pIds = orgPlans[orgId];
        for (uint256 i = 0; i < pIds.length; i++) {
            uint256 rawId = _planHolderPass[pIds[i]][holder];
            if (rawId == 0) continue;
            uint256 passId = rawId - 1;
            MembershipPass storage pass = passes[passId];
            if (pass.status == PassStatus.Active &&
                (pass.expiresAt == 0 || pass.expiresAt >= block.timestamp)) {
                return (true, pIds[i]);
            }
        }
        return (false, 0);
    }

    /**
     * @notice Get the live status of a pass (re-checks expiry).
     */
    function getPassStatus(uint256 passId) external view returns (PassStatus) {
        MembershipPass storage pass = passes[passId];
        if (pass.status == PassStatus.Active &&
            pass.expiresAt != 0 &&
            pass.expiresAt < block.timestamp) {
            return PassStatus.Expired;
        }
        return pass.status;
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEW HELPERS
    // ─────────────────────────────────────────────────────────────────────

    function getOwnerOrgs(address owner) external view returns (uint256[] memory) {
        return ownerOrgs[owner];
    }

    function getOrgPlans(uint256 orgId) external view returns (uint256[] memory) {
        return orgPlans[orgId];
    }

    function getOrgPasses(uint256 orgId) external view returns (uint256[] memory) {
        return orgPasses[orgId];
    }

    function getHolderPasses(address holder) external view returns (uint256[] memory) {
        return holderPasses[holder];
    }

    function getPlanInvitations(uint256 planId) external view returns (uint256[] memory) {
        return planInvitations[planId];
    }

    function getHolderPassForPlan(address holder, uint256 planId) external view returns (bool exists, uint256 passId) {
        uint256 rawId = _planHolderPass[planId][holder];
        if (rawId == 0) return (false, 0);
        return (true, rawId - 1);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ADMIN
    // ─────────────────────────────────────────────────────────────────────

    function setOrgActive(uint256 orgId, bool active) external onlyAdmin {
        orgs[orgId].active = active;
    }

    function setPaused(bool state) external onlyAdmin {
        paused = state;
        emit Paused(state);
    }

    function setTreasury(address _treasury) external onlyAdmin {
        require(_treasury != address(0), "Access: zero address");
        treasury = _treasury;
    }

    function initiateAdminTransfer(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Access: zero address");
        pendingAdmin = newAdmin;
        emit AdminTransferInitiated(newAdmin);
    }

    function acceptAdminTransfer() external {
        require(msg.sender == pendingAdmin, "Access: not pending admin");
        emit AdminTransferred(admin, msg.sender);
        admin        = msg.sender;
        pendingAdmin = address(0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL
    // ─────────────────────────────────────────────────────────────────────

    function _mintPass(
        uint256 planId,
        MembershipPlan storage plan,
        address holder,
        bool isInvitation
    ) internal returns (uint256 passId) {
        uint40 expiresAt = 0;
        if (plan.durationDays > 0) {
            expiresAt = uint40(block.timestamp) + uint40(plan.durationDays) * 1 days;
        }

        passId = passCount++;
        passes[passId] = MembershipPass({
            orgId:        plan.orgId,
            planId:       planId,
            holder:       holder,
            status:       PassStatus.Active,
            issuedAt:     uint40(block.timestamp),
            expiresAt:    expiresAt,
            suspendedAt:  0,
            revokedAt:    0,
            revokeReason: "",
            isInvitation: isInvitation
        });

        plan.currentMembers++;
        orgPasses[plan.orgId].push(passId);
        holderPasses[holder].push(passId);
        _planHolderPass[planId][holder] = passId + 1; // +1 so 0 means "none"

        emit PassIssued(passId, planId, holder);
    }

    function _requireOrgOwnerForPass(uint256 passId) internal view {
        uint256 orgId = passes[passId].orgId;
        require(orgs[orgId].owner == msg.sender, "Access: not org owner");
    }

    receive() external payable {}
}
