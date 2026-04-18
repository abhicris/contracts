// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HanzoRegistry} from "../src/identity-registry/HanzoRegistry.sol";

/**
 * @title HanzoRegistry Foundry Test Suite
 * @notice Behaviour + invariant coverage for the identity registry deployed behind UUPS proxy.
 *
 * Covers:
 *  - validName() rule set: length 1..63, alphanumeric + underscore.
 *  - identityStakeRequirement() pricing tiers (1/2/3/4+ char) and 50% referrer discount.
 *  - claimIdentity() happy path: records ownership, transfers stake, mints NFT, emits events.
 *  - claimIdentity() reverts: invalid name, invalid namespace, duplicate, insufficient stake.
 *  - setData / setKeys / setNodeAddress / setProxyNodes owner-only gating.
 *  - increaseStake and decreaseStake accounting + overdraw revert.
 *  - setDelegations clearing + totalDelegated bookkeeping + over-delegation revert.
 *  - updateRecords arity mismatch revert + read-back via identityRecords getter.
 *  - unclaimIdentity returns stake, burns NFT, clears owner mapping.
 *  - setNamespace / setBaseRewardsRate: onlyOwner, cap enforcement.
 *  - Fuzz: validName rejects any byte outside the allowed classes.
 *  - Fuzz: stake requirement scales by name length tier and halves with referrer.
 */
contract HanzoRegistryTest is Test {
    HanzoRegistry internal registryImpl;
    HanzoRegistry internal registry;

    MockToken internal token;
    MockNft internal nft;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA71);
    address internal bob = address(0xB71);

    uint256 internal constant HANZO_MAINNET = 36_963;
    uint256 internal constant LUX_MAINNET = 96_369;
    uint256 internal constant INVALID_NS = 123_456;
    uint256 internal constant ONE = 1e18;

    event IdentityClaim(string indexed identity, uint256 nftTokenId, string identityRaw, address owner);
    event IdentityUnclaim(string indexed identity, uint256 nftTokenId);
    event StakeUpdate(string indexed identity, uint256 newStake);
    event KeysUpdate(string indexed identity, string encryptionKey, string signatureKey);
    event BaseRewardsRateUpdate(uint256 newRate);

    function setUp() public {
        token = new MockToken();
        nft = new MockNft();

        registryImpl = new HanzoRegistry();
        bytes memory initData = abi.encodeCall(
            HanzoRegistry.initialize,
            (owner, address(token), address(nft))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(registryImpl), initData);
        registry = HanzoRegistry(address(proxy));

        // Fund alice & bob with plenty of MockToken and pre-approve the registry.
        token.mint(alice, 1_000_000 * ONE);
        token.mint(bob, 1_000_000 * ONE);
        vm.prank(alice);
        token.approve(address(registry), type(uint256).max);
        vm.prank(bob);
        token.approve(address(registry), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function test_Initialize_SeedsNamespaces() public {
        assertEq(registry.namespaces(36_963), "hanzo");
        assertEq(registry.namespaces(96_369), "lux");
        assertEq(registry.namespaces(200_200), "zoo");
        assertEq(registry.namespaces(11_155_111), "sepolia");
    }

    function test_Initialize_SetsOwnerAndTokenRefs() public {
        assertEq(registry.owner(), owner);
        assertEq(address(registry.shinToken()), address(token));
        assertEq(address(registry.hanzoNft()), address(nft));
    }

    function test_Initialize_SetsBaseRewardsRateAndRewardsState() public {
        assertEq(registry.baseRewardsRate(), 1e16);
        (uint224 idx, uint32 blk) = registry.rewardsState();
        assertEq(idx, 1e36);
        assertEq(uint256(blk), block.number);
    }

    function test_Initialize_CannotBeCalledTwice() public {
        vm.expectRevert(); // Initializable's InvalidInitialization
        registry.initialize(owner, address(token), address(nft));
    }

    // ---------------------------------------------------------------------
    // validName
    // ---------------------------------------------------------------------

    function test_ValidName_AcceptsAlphanumericUnderscore() public {
        assertTrue(registry.validName("alice"));
        assertTrue(registry.validName("Alice_2026"));
        assertTrue(registry.validName("A"));
        assertTrue(registry.validName("0"));
        assertTrue(registry.validName("_"));
    }

    function test_ValidName_RejectsEmpty() public {
        assertFalse(registry.validName(""));
    }

    function test_ValidName_RejectsTooLong() public {
        bytes memory b = new bytes(64);
        for (uint256 i = 0; i < 64; i++) b[i] = bytes1("a");
        assertFalse(registry.validName(string(b)));
    }

    function test_ValidName_RejectsHyphen() public {
        assertFalse(registry.validName("alice-bob"));
    }

    function test_ValidName_RejectsDot() public {
        assertFalse(registry.validName("alice.bob"));
    }

    function test_ValidName_Accepts63Chars() public {
        bytes memory b = new bytes(63);
        for (uint256 i = 0; i < 63; i++) b[i] = bytes1("x");
        assertTrue(registry.validName(string(b)));
    }

    // ---------------------------------------------------------------------
    // Pricing
    // ---------------------------------------------------------------------

    function test_IdentityStakeRequirement_Tiers() public {
        assertEq(registry.identityStakeRequirement("a", HANZO_MAINNET, false), 10_000 * ONE);
        assertEq(registry.identityStakeRequirement("ab", HANZO_MAINNET, false), 5_000 * ONE);
        assertEq(registry.identityStakeRequirement("abc", HANZO_MAINNET, false), 1_000 * ONE);
        assertEq(registry.identityStakeRequirement("abcd", HANZO_MAINNET, false), 100 * ONE);
        assertEq(registry.identityStakeRequirement("abcdefghij", HANZO_MAINNET, false), 100 * ONE);
    }

    function test_IdentityStakeRequirement_ReferrerHalfPrice() public {
        assertEq(registry.identityStakeRequirement("alice", HANZO_MAINNET, true), 50 * ONE);
        assertEq(registry.identityStakeRequirement("a", HANZO_MAINNET, true), 5_000 * ONE);
    }

    // ---------------------------------------------------------------------
    // claimIdentity — happy path + reverts
    // ---------------------------------------------------------------------

    function _defaultParams(string memory name, address who)
        internal
        view
        returns (HanzoRegistry.ClaimIdentityParams memory)
    {
        return HanzoRegistry.ClaimIdentityParams({
            name: name,
            namespace: HANZO_MAINNET,
            stakeAmount: 100 * ONE,
            owner: who,
            referrer: ""
        });
    }

    function test_ClaimIdentity_Succeeds() public {
        HanzoRegistry.ClaimIdentityParams memory p = _defaultParams("alice", alice);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        registry.claimIdentity(p);

        assertEq(registry.ownerOf("@alice.hanzo"), alice, "owner mapping set");
        assertEq(aliceBefore - token.balanceOf(alice), 100 * ONE, "stake transferred");
        assertEq(token.balanceOf(address(registry)), 100 * ONE, "registry holds stake");

        HanzoRegistry.IdentityData memory d = registry.getIdentityData("@alice.hanzo");
        assertEq(d.stakedTokens, 100 * ONE);
        assertEq(d.delegatedTokens, 0);
        assertEq(nft.ownerOf(d.boundNft), alice, "NFT minted to claimer-owner");
    }

    function test_ClaimIdentity_EmitsIdentityClaimAndStakeUpdate() public {
        HanzoRegistry.ClaimIdentityParams memory p = _defaultParams("alice", alice);

        // IdentityClaim has `identity` indexed (keccak of string is the topic) + raw string in data.
        vm.expectEmit(true, false, false, true, address(registry));
        emit IdentityClaim("@alice.hanzo", 0, "@alice.hanzo", alice);
        vm.expectEmit(true, false, false, true, address(registry));
        emit StakeUpdate("@alice.hanzo", 100 * ONE);

        vm.prank(alice);
        registry.claimIdentity(p);
    }

    function test_ClaimIdentity_RevertsOnInvalidName() public {
        HanzoRegistry.ClaimIdentityParams memory p = _defaultParams("bad-name", alice);
        vm.prank(alice);
        vm.expectRevert();
        registry.claimIdentity(p);
    }

    function test_ClaimIdentity_RevertsOnInvalidNamespace() public {
        HanzoRegistry.ClaimIdentityParams memory p = _defaultParams("alice", alice);
        p.namespace = INVALID_NS;
        vm.prank(alice);
        vm.expectRevert();
        registry.claimIdentity(p);
    }

    function test_ClaimIdentity_RevertsOnDuplicate() public {
        HanzoRegistry.ClaimIdentityParams memory p = _defaultParams("alice", alice);
        vm.prank(alice);
        registry.claimIdentity(p);

        vm.prank(bob);
        vm.expectRevert();
        registry.claimIdentity(p);
    }

    function test_ClaimIdentity_RevertsOnInsufficientStake() public {
        HanzoRegistry.ClaimIdentityParams memory p = _defaultParams("a", alice); // 1-char needs 10k
        p.stakeAmount = 1 * ONE;
        vm.prank(alice);
        vm.expectRevert();
        registry.claimIdentity(p);
    }

    function test_ClaimIdentityBatched_ClaimsAll() public {
        HanzoRegistry.ClaimIdentityParams[] memory batch = new HanzoRegistry.ClaimIdentityParams[](3);
        batch[0] = _defaultParams("one", alice);
        batch[0].stakeAmount = 1_000 * ONE; // 3-char tier
        batch[1] = _defaultParams("two", alice);
        batch[1].stakeAmount = 1_000 * ONE;
        batch[2] = _defaultParams("three", alice);
        batch[2].stakeAmount = 100 * ONE;

        vm.prank(alice);
        registry.claimIdentityBatched(batch);

        assertEq(registry.ownerOf("@one.hanzo"), alice);
        assertEq(registry.ownerOf("@two.hanzo"), alice);
        assertEq(registry.ownerOf("@three.hanzo"), alice);
    }

    // ---------------------------------------------------------------------
    // setData / setKeys / setNodeAddress / setProxyNodes
    // ---------------------------------------------------------------------

    function _claimAsAlice(string memory name) internal {
        HanzoRegistry.ClaimIdentityParams memory p = _defaultParams(name, alice);
        vm.prank(alice);
        registry.claimIdentity(p);
    }

    function test_SetKeys_OnlyOwnerCanUpdate() public {
        _claimAsAlice("alice");

        vm.prank(bob);
        vm.expectRevert();
        registry.setKeys("@alice.hanzo", "ek", "sk");

        vm.expectEmit(true, false, false, true, address(registry));
        emit KeysUpdate("@alice.hanzo", "ek", "sk");
        vm.prank(alice);
        registry.setKeys("@alice.hanzo", "ek", "sk");

        HanzoRegistry.IdentityData memory d = registry.getIdentityData("@alice.hanzo");
        assertEq(d.encryptionKey, "ek");
        assertEq(d.signatureKey, "sk");
    }

    function test_SetNodeAddress_SetsRoutingTrue() public {
        _claimAsAlice("alice");

        vm.prank(alice);
        registry.setNodeAddress("@alice.hanzo", "https://alice.node");

        HanzoRegistry.IdentityData memory d = registry.getIdentityData("@alice.hanzo");
        assertTrue(d.routing);
        assertEq(d.addressOrProxyNodes.length, 1);
        assertEq(d.addressOrProxyNodes[0], "https://alice.node");
    }

    function test_SetProxyNodes_SetsRoutingFalse() public {
        _claimAsAlice("alice");

        string[] memory nodes = new string[](2);
        nodes[0] = "https://proxy1";
        nodes[1] = "https://proxy2";

        vm.prank(alice);
        registry.setProxyNodes("@alice.hanzo", nodes);

        HanzoRegistry.IdentityData memory d = registry.getIdentityData("@alice.hanzo");
        assertFalse(d.routing);
        assertEq(d.addressOrProxyNodes.length, 2);
    }

    function test_ResetIdentityData_ClearsKeysAndNodes() public {
        _claimAsAlice("alice");
        vm.startPrank(alice);
        registry.setKeys("@alice.hanzo", "ek", "sk");
        string[] memory nodes = new string[](1);
        nodes[0] = "https://alice.node";
        registry.setProxyNodes("@alice.hanzo", nodes);
        registry.resetIdentityData("@alice.hanzo");
        vm.stopPrank();

        HanzoRegistry.IdentityData memory d = registry.getIdentityData("@alice.hanzo");
        assertEq(d.encryptionKey, "");
        assertEq(d.signatureKey, "");
        assertEq(d.addressOrProxyNodes.length, 0);
        assertFalse(d.routing);
    }

    // ---------------------------------------------------------------------
    // increase / decrease stake
    // ---------------------------------------------------------------------

    function test_IncreaseStake_UpdatesAccounting() public {
        _claimAsAlice("alice");

        vm.prank(alice);
        registry.increaseStake("@alice.hanzo", 250 * ONE);

        HanzoRegistry.IdentityData memory d = registry.getIdentityData("@alice.hanzo");
        assertEq(d.stakedTokens, 100 * ONE + 250 * ONE);
        assertEq(token.balanceOf(address(registry)), 350 * ONE);
    }

    function test_DecreaseStake_RevertsWhenOverdrawn() public {
        _claimAsAlice("alice");
        vm.prank(alice);
        vm.expectRevert();
        registry.decreaseStake("alice", HANZO_MAINNET, 101 * ONE);
    }

    function test_DecreaseStake_Succeeds() public {
        _claimAsAlice("alice");

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        registry.decreaseStake("alice", HANZO_MAINNET, 60 * ONE);

        HanzoRegistry.IdentityData memory d = registry.getIdentityData("@alice.hanzo");
        assertEq(d.stakedTokens, 40 * ONE);
        assertEq(token.balanceOf(alice) - aliceBefore, 60 * ONE);
    }

    // ---------------------------------------------------------------------
    // Delegations
    // ---------------------------------------------------------------------

    function test_SetDelegations_RecordsTotalDelegated() public {
        _claimAsAlice("alice");
        vm.prank(alice);
        registry.increaseStake("@alice.hanzo", 400 * ONE); // staked = 500

        HanzoRegistry.Delegation[] memory d = new HanzoRegistry.Delegation[](2);
        d[0] = HanzoRegistry.Delegation({delegatee: "@bob.hanzo", amount: 100 * ONE});
        d[1] = HanzoRegistry.Delegation({delegatee: "@carol.hanzo", amount: 200 * ONE});

        vm.prank(alice);
        registry.setDelegations("@alice.hanzo", d);

        HanzoRegistry.IdentityData memory info = registry.getIdentityData("@alice.hanzo");
        assertEq(info.delegatedTokens, 300 * ONE);
        assertEq(registry.identityDelegations("@alice.hanzo", "@bob.hanzo"), 100 * ONE);
        assertEq(registry.getAvailableTokensForDelegation("@alice.hanzo"), 200 * ONE);

        string[] memory delegatees = registry.getDelegatees("@alice.hanzo");
        assertEq(delegatees.length, 2);
    }

    function test_SetDelegations_RevertsOnOverDelegation() public {
        _claimAsAlice("alice"); // staked 100
        HanzoRegistry.Delegation[] memory d = new HanzoRegistry.Delegation[](1);
        d[0] = HanzoRegistry.Delegation({delegatee: "@bob.hanzo", amount: 101 * ONE});

        vm.prank(alice);
        vm.expectRevert();
        registry.setDelegations("@alice.hanzo", d);
    }

    function test_SetDelegations_RevertsOnZeroAmountEntry() public {
        _claimAsAlice("alice");
        HanzoRegistry.Delegation[] memory d = new HanzoRegistry.Delegation[](1);
        d[0] = HanzoRegistry.Delegation({delegatee: "@bob.hanzo", amount: 0});

        vm.prank(alice);
        vm.expectRevert();
        registry.setDelegations("@alice.hanzo", d);
    }

    function test_SetDelegations_ReplacesPriorSet() public {
        _claimAsAlice("alice");
        vm.prank(alice);
        registry.increaseStake("@alice.hanzo", 400 * ONE);

        HanzoRegistry.Delegation[] memory first = new HanzoRegistry.Delegation[](2);
        first[0] = HanzoRegistry.Delegation({delegatee: "@x.hanzo", amount: 100 * ONE});
        first[1] = HanzoRegistry.Delegation({delegatee: "@y.hanzo", amount: 100 * ONE});
        vm.prank(alice);
        registry.setDelegations("@alice.hanzo", first);

        HanzoRegistry.Delegation[] memory second = new HanzoRegistry.Delegation[](1);
        second[0] = HanzoRegistry.Delegation({delegatee: "@z.hanzo", amount: 50 * ONE});
        vm.prank(alice);
        registry.setDelegations("@alice.hanzo", second);

        // Old entries cleared out
        assertEq(registry.identityDelegations("@alice.hanzo", "@x.hanzo"), 0);
        assertEq(registry.identityDelegations("@alice.hanzo", "@y.hanzo"), 0);
        assertEq(registry.identityDelegations("@alice.hanzo", "@z.hanzo"), 50 * ONE);
    }

    // ---------------------------------------------------------------------
    // Records
    // ---------------------------------------------------------------------

    function test_UpdateRecords_WritesAndReadsBack() public {
        _claimAsAlice("alice");
        string[] memory k = new string[](2);
        k[0] = "url";
        k[1] = "bio";
        string[] memory v = new string[](2);
        v[0] = "https://alice.xyz";
        v[1] = "hi";

        vm.prank(alice);
        registry.updateRecords("@alice.hanzo", k, v);

        assertEq(registry.identityRecords("@alice.hanzo", "url"), "https://alice.xyz");
        assertEq(registry.identityRecords("@alice.hanzo", "bio"), "hi");
    }

    function test_UpdateRecords_RevertsOnArityMismatch() public {
        _claimAsAlice("alice");
        string[] memory k = new string[](2);
        k[0] = "a";
        k[1] = "b";
        string[] memory v = new string[](1);
        v[0] = "x";

        vm.prank(alice);
        vm.expectRevert();
        registry.updateRecords("@alice.hanzo", k, v);
    }

    function test_UpdateRecords_OnlyOwner() public {
        _claimAsAlice("alice");
        string[] memory k = new string[](1);
        k[0] = "a";
        string[] memory v = new string[](1);
        v[0] = "x";

        vm.prank(bob);
        vm.expectRevert();
        registry.updateRecords("@alice.hanzo", k, v);
    }

    // ---------------------------------------------------------------------
    // Unclaim
    // ---------------------------------------------------------------------

    function test_UnclaimIdentity_ReturnsStakeAndClearsOwner() public {
        _claimAsAlice("alice");

        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(registry));
        emit IdentityUnclaim("@alice.hanzo", 0);
        vm.prank(alice);
        registry.unclaimIdentity("@alice.hanzo");

        assertEq(token.balanceOf(alice) - aliceBalBefore, 100 * ONE, "stake refunded");
        assertEq(registry.ownerOf("@alice.hanzo"), address(0), "owner cleared");
        // NFT burn: ownerOf on burned id returns 0 in mock
        assertEq(nft.ownerOf(0), address(0), "nft burned");
    }

    function test_UnclaimIdentity_OnlyOwner() public {
        _claimAsAlice("alice");
        vm.prank(bob);
        vm.expectRevert();
        registry.unclaimIdentity("@alice.hanzo");
    }

    // ---------------------------------------------------------------------
    // Admin ops
    // ---------------------------------------------------------------------

    function test_SetNamespace_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.setNamespace(9_999, "new");

        vm.prank(owner);
        registry.setNamespace(9_999, "new");
        assertEq(registry.namespaces(9_999), "new");
    }

    function test_SetBaseRewardsRate_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.setBaseRewardsRate(1e14);
    }

    function test_SetBaseRewardsRate_RevertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert();
        registry.setBaseRewardsRate(1e18 + 1);
    }

    function test_SetBaseRewardsRate_Succeeds_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(registry));
        emit BaseRewardsRateUpdate(5e15);
        vm.prank(owner);
        registry.setBaseRewardsRate(5e15);
        assertEq(registry.baseRewardsRate(), 5e15);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// @dev validName must reject any single-byte string whose byte is outside [0-9A-Za-z_].
    function testFuzz_ValidName_RejectsOutOfClassByte(uint8 b) public {
        bool inRange =
            (b >= 0x30 && b <= 0x39) ||
            (b >= 0x41 && b <= 0x5A) ||
            (b >= 0x61 && b <= 0x7A) ||
            (b == 0x5F);

        string memory s = string(abi.encodePacked(bytes1(b)));
        assertEq(registry.validName(s), inRange);
    }

    /// @dev Stake requirement with referrer is exactly half of without-referrer.
    function testFuzz_StakeRequirement_ReferrerHalvesCost(uint8 nameLen) public {
        nameLen = uint8(bound(uint256(nameLen), 1, 63));
        bytes memory b = new bytes(nameLen);
        for (uint256 i = 0; i < nameLen; i++) b[i] = bytes1("x");

        uint256 full = registry.identityStakeRequirement(string(b), HANZO_MAINNET, false);
        uint256 half = registry.identityStakeRequirement(string(b), HANZO_MAINNET, true);
        assertEq(half * 2, full, "referrer discount is exactly 50%");
    }

    /// @dev Stake requirement monotonically decreases (or stays equal) as name length increases.
    function testFuzz_StakeRequirement_NonIncreasingInLength(uint8 a, uint8 bLen) public {
        a = uint8(bound(uint256(a), 1, 63));
        bLen = uint8(bound(uint256(bLen), 1, 63));
        vm.assume(a < bLen);

        bytes memory na = new bytes(a);
        bytes memory nb = new bytes(bLen);
        for (uint256 i = 0; i < a; i++) na[i] = bytes1("x");
        for (uint256 i = 0; i < bLen; i++) nb[i] = bytes1("x");

        uint256 sa = registry.identityStakeRequirement(string(na), HANZO_MAINNET, false);
        uint256 sb = registry.identityStakeRequirement(string(nb), HANZO_MAINNET, false);
        assertGe(sa, sb, "shorter name costs >= longer name");
    }
}

// ==========================================================================
// Mocks — minimal implementations sufficient for registry unit tests.
// ==========================================================================

contract MockToken is IERC20 {
    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _allow;
    uint256 private _total;

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
        _total += amount;
    }

    function totalSupply() external view returns (uint256) {
        return _total;
    }

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _bal[msg.sender] -= amount;
        _bal[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address o, address s) external view returns (uint256) {
        return _allow[o][s];
    }

    function approve(address s, uint256 amount) external returns (bool) {
        _allow[msg.sender][s] = amount;
        emit Approval(msg.sender, s, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        if (a != type(uint256).max) {
            _allow[from][msg.sender] = a - amount;
        }
        _bal[from] -= amount;
        _bal[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockNft {
    uint256 private _next;
    mapping(uint256 => address) private _owners;

    event Transfer(address indexed from, address indexed to, uint256 indexed id);

    function mint(address to) external returns (uint256) {
        uint256 id = _next++;
        _owners[id] = to;
        emit Transfer(address(0), to, id);
        return id;
    }

    function burn(uint256 id) external {
        address o = _owners[id];
        delete _owners[id];
        emit Transfer(o, address(0), id);
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owners[id];
    }
}
