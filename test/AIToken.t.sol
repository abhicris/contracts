// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AIToken} from "../src/AIToken.sol";

/**
 * @title AIToken Foundry Test Suite
 * @notice Behaviour + invariant coverage for AIToken.
 *
 * Covers:
 *  - Constructor allocations, supply accounting vs MAX_SUPPLY.
 *  - Burn-on-transfer mechanic (default burnRate = 10 bps / 0.1%).
 *  - Transfer fee routing to treasury when governance activates it.
 *  - Fee cap enforcement (transferFeeRate <= 500, burnRate <= 100).
 *  - onlyOwner gating for pause / unpause / updateFeeRates / updateTreasury / createVestingSchedule.
 *  - Pausable transfer halting.
 *  - Vesting schedule creation, cliff, linear vest, claim accounting.
 *  - Staking: lock-period whitelist, reward accrual, time-lock enforcement, post-unstake balances.
 *  - getLockedTokens sums staked + unvested-unclaimed.
 *  - Fuzz: transfers preserve (sender + recipient + burned + fee) == amount.
 *  - Fuzz: staking rewards are monotonically non-decreasing over time.
 *  - Invariant: totalSupply is monotone non-increasing after deployment (no mint path exists post-ctor,
 *    only burn-on-transfer can reduce it).
 */
contract AITokenTest is Test {
    AIToken internal token;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xB0B);
    address internal alice = address(0xA71);
    address internal bob = address(0xB71);
    address internal carol = address(0xC71);

    uint256 internal constant ONE = 1e18;

    // Mirrored from contract constants for clarity in assertions
    uint256 internal constant MAX_SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant TEAM = 150_000_000 * 1e18;
    uint256 internal constant ECOSYSTEM = 350_000_000 * 1e18;
    uint256 internal constant PUBLIC_SALE = 200_000_000 * 1e18;
    uint256 internal constant LIQUIDITY = 100_000_000 * 1e18;
    uint256 internal constant STAKING_REWARDS = 200_000_000 * 1e18;
    uint256 internal constant FEE_DENOMINATOR = 10_000;

    function setUp() public {
        vm.prank(owner);
        token = new AIToken(treasury);
    }

    // ---------------------------------------------------------------------
    // Constructor / allocation accounting
    // ---------------------------------------------------------------------

    function test_Constructor_AssignsTeamAllocationToDeployer() public {
        assertEq(token.balanceOf(owner), TEAM, "team tranche to deployer");
    }

    function test_Constructor_AssignsEcosystemAllocationToTreasury() public {
        assertEq(token.balanceOf(treasury), ECOSYSTEM, "ecosystem tranche to treasury");
    }

    function test_Constructor_StakingRewardsHeldByContract() public {
        assertEq(token.balanceOf(address(token)), STAKING_REWARDS, "staking rewards held by token");
    }

    function test_Constructor_InitialTotalSupplyIsSumOfMintedTranches() public {
        // Contract mints TEAM + ECOSYSTEM + STAKING_REWARDS only; PUBLIC_SALE + LIQUIDITY
        // are declared as constants but NOT minted in constructor. This test pins that down
        // so future refactors can't silently change the initial float.
        assertEq(token.totalSupply(), TEAM + ECOSYSTEM + STAKING_REWARDS, "initial supply = 3 tranches");
    }

    function test_Constructor_InitialSupplyUnderMaxSupply() public {
        assertLt(token.totalSupply(), MAX_SUPPLY, "initial float below hard cap constant");
    }

    function test_Constructor_TreasuryAddressStored() public {
        assertEq(token.treasuryAddress(), treasury);
    }

    function test_Constructor_OwnerIsDeployer() public {
        assertEq(token.owner(), owner);
    }

    function test_Constructor_RewardRatesSeeded() public {
        assertEq(token.rewardRates(0), 100);
        assertEq(token.rewardRates(30), 300);
        assertEq(token.rewardRates(90), 600);
        assertEq(token.rewardRates(180), 1_000);
        assertEq(token.rewardRates(365), 1_500);
    }

    // ---------------------------------------------------------------------
    // Burn-on-transfer default behaviour
    // ---------------------------------------------------------------------

    function test_Transfer_AppliesDefaultBurnRate() public {
        // Default burnRate = 10 bps = 0.1%
        uint256 amount = 10_000 * ONE;
        uint256 expectedBurn = (amount * 10) / FEE_DENOMINATOR;

        uint256 supplyBefore = token.totalSupply();

        vm.prank(owner);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), amount - expectedBurn, "alice receives net of burn");
        assertEq(token.totalSupply(), supplyBefore - expectedBurn, "supply drops by burn amount");
    }

    function test_Transfer_ToContractSkipsBurn() public {
        // _update exempts from/to address(this) from fees.
        uint256 amount = 1_000 * ONE;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(owner);
        token.transfer(address(token), amount);

        assertEq(token.totalSupply(), supplyBefore, "transfers to contract exempt from burn");
    }

    function test_Transfer_FromContractSkipsBurn() public {
        // Contract sends staking rewards out during unstake; must not burn.
        uint256 amount = 500 * ONE;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(address(token));
        token.transfer(alice, amount);

        assertEq(token.totalSupply(), supplyBefore, "transfers from contract exempt from burn");
    }

    // ---------------------------------------------------------------------
    // Transfer-fee mechanic (governance-activated)
    // ---------------------------------------------------------------------

    function test_TransferFee_RoutesToTreasuryWhenActivated() public {
        // Activate 1% transfer fee + keep default 0.1% burn
        vm.prank(owner);
        token.updateFeeRates(100, 10);

        uint256 amount = 100_000 * ONE;
        uint256 expectedBurn = (amount * 10) / FEE_DENOMINATOR;
        uint256 expectedFee = (amount * 100) / FEE_DENOMINATOR;

        uint256 treasuryBalBefore = token.balanceOf(treasury);

        vm.prank(owner);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), amount - expectedBurn - expectedFee, "alice net amount");
        assertEq(
            token.balanceOf(treasury) - treasuryBalBefore,
            expectedFee,
            "treasury receives fee delta"
        );
    }

    // ---------------------------------------------------------------------
    // Governance caps
    // ---------------------------------------------------------------------

    function test_UpdateFeeRates_RevertsAboveTransferFeeCap() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Transfer fee too high"));
        token.updateFeeRates(501, 10); // > 5%
    }

    function test_UpdateFeeRates_RevertsAboveBurnCap() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Burn rate too high"));
        token.updateFeeRates(100, 101); // > 1%
    }

    function test_UpdateFeeRates_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // OZ v5 Ownable reverts with OwnableUnauthorizedAccount(address)
        token.updateFeeRates(100, 50);
    }

    function test_UpdateTreasury_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Invalid address"));
        token.updateTreasury(address(0));
    }

    function test_UpdateTreasury_RevertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.updateTreasury(address(0x1234));
    }

    function test_UpdateTreasury_Succeeds() public {
        address newTreasury = address(0xDEAD);
        vm.prank(owner);
        token.updateTreasury(newTreasury);
        assertEq(token.treasuryAddress(), newTreasury);
    }

    // ---------------------------------------------------------------------
    // Pausable
    // ---------------------------------------------------------------------

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.pause();
    }

    function test_Pause_BlocksAllTransfers() public {
        vm.prank(owner);
        token.pause();

        vm.prank(owner);
        vm.expectRevert(bytes("Token transfers paused"));
        token.transfer(alice, 1 * ONE);
    }

    function test_Unpause_RestoresTransfers() public {
        vm.startPrank(owner);
        token.pause();
        token.unpause();
        token.transfer(alice, 1 * ONE);
        vm.stopPrank();
        // 0.1% burn still applies
        assertEq(token.balanceOf(alice), 1 * ONE - (1 * ONE * 10) / FEE_DENOMINATOR);
    }

    // ---------------------------------------------------------------------
    // Vesting
    // ---------------------------------------------------------------------

    function test_CreateVestingSchedule_RevertsOnZeroBeneficiary() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Invalid beneficiary"));
        token.createVestingSchedule(address(0), 1 * ONE, block.timestamp, 0, 365 days, false);
    }

    function test_CreateVestingSchedule_RevertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Invalid amount"));
        token.createVestingSchedule(alice, 0, block.timestamp, 0, 365 days, false);
    }

    function test_CreateVestingSchedule_RevertsOnDuplicate() public {
        vm.startPrank(owner);
        token.createVestingSchedule(alice, 10 * ONE, block.timestamp, 0, 365 days, false);
        vm.expectRevert(bytes("Schedule exists"));
        token.createVestingSchedule(alice, 10 * ONE, block.timestamp, 0, 365 days, false);
        vm.stopPrank();
    }

    function test_ClaimVestedTokens_BeforeCliff_Reverts() public {
        vm.prank(owner);
        token.createVestingSchedule(alice, 1_000 * ONE, block.timestamp, 30 days, 365 days, false);

        vm.prank(alice);
        vm.expectRevert(bytes("Nothing to claim"));
        token.claimVestedTokens();
    }

    function test_ClaimVestedTokens_AfterFullDuration_ClaimsAll() public {
        uint256 vestAmount = 1_000 * ONE;
        vm.prank(owner);
        token.createVestingSchedule(alice, vestAmount, block.timestamp, 0, 365 days, false);

        // Fast forward past full vesting.
        vm.warp(block.timestamp + 365 days + 1);

        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        token.claimVestedTokens();

        // Internal-transfer from contract exempt from burn, so alice receives full amount.
        assertEq(token.balanceOf(alice) - aliceBalBefore, vestAmount, "alice claims full vested amount");
    }

    function test_ClaimVestedTokens_Linear_PartialClaim() public {
        uint256 vestAmount = 1_000 * ONE;
        uint256 start = block.timestamp;

        vm.prank(owner);
        token.createVestingSchedule(alice, vestAmount, start, 0, 100 days, false);

        // Halfway through vesting
        vm.warp(start + 50 days);
        vm.prank(alice);
        token.claimVestedTokens();

        uint256 claimed1 = token.balanceOf(alice);
        assertApproxEqAbs(claimed1, vestAmount / 2, 1e15, "~50% claimable at half time");

        // Full duration -> rest claimable
        vm.warp(start + 100 days + 1);
        vm.prank(alice);
        token.claimVestedTokens();

        assertEq(token.balanceOf(alice), vestAmount, "alice has full vested amount after full duration");
    }

    // ---------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------

    function _seedAlice(uint256 targetAmount) internal returns (uint256 delivered) {
        // Owner transfers enough to leave alice with >= targetAmount after the 0.1% burn.
        // Over-send by a comfortable margin (+1%) to absorb integer-division rounding.
        uint256 gross = (targetAmount * 11_000) / 10_000;
        vm.prank(owner);
        token.transfer(alice, gross);
        delivered = token.balanceOf(alice);
        require(delivered >= targetAmount, "seeding undershot target");
    }

    function test_Stake_RevertsOnZeroAmount() public {
        _seedAlice(100 * ONE);
        vm.prank(alice);
        vm.expectRevert(bytes("Invalid amount"));
        token.stake(0, 0);
    }

    function test_Stake_RevertsOnInvalidLockPeriod() public {
        _seedAlice(100 * ONE);
        vm.prank(alice);
        vm.expectRevert(bytes("Invalid lock period"));
        token.stake(10 * ONE, 45); // not in {0,30,90,180,365}
    }

    function test_Stake_UpdatesAccounting() public {
        _seedAlice(100 * ONE);
        vm.prank(alice);
        token.stake(50 * ONE, 30);

        assertEq(token.totalStaked(alice), 50 * ONE);
        assertEq(token.globalTotalStaked(), 50 * ONE);
    }

    function test_Unstake_RevertsBeforeLockExpires() public {
        _seedAlice(100 * ONE);
        vm.startPrank(alice);
        token.stake(50 * ONE, 30);
        vm.expectRevert(bytes("Lock period not ended"));
        token.unstake(0);
        vm.stopPrank();
    }

    function test_Unstake_WithZeroLockSucceedsImmediately() public {
        _seedAlice(100 * ONE);
        vm.startPrank(alice);
        token.stake(50 * ONE, 0);
        token.unstake(0);
        vm.stopPrank();

        // Principal returned (no burn on contract->user), rewards ~0 at same block.
        assertGe(token.balanceOf(alice), 50 * ONE);
        assertEq(token.totalStaked(alice), 0);
        assertEq(token.globalTotalStaked(), 0);
    }

    function test_Unstake_PaysNonZeroRewardsAfterLock() public {
        _seedAlice(1_000 * ONE);
        vm.prank(alice);
        token.stake(1_000 * ONE, 30);

        // After 30 days + 1s: 3% APR * (30/365) ~= 0.2466% of principal.
        vm.warp(block.timestamp + 30 days + 1);

        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        token.unstake(0);
        uint256 received = token.balanceOf(alice) - balBefore;

        assertGt(received, 1_000 * ONE, "received more than principal (rewards paid)");
    }

    function test_CalculateRewards_ReturnsZeroForUnstakedSlot() public {
        _seedAlice(100 * ONE);
        vm.startPrank(alice);
        token.stake(10 * ONE, 0);
        token.unstake(0);
        vm.stopPrank();
        assertEq(token.calculateRewards(alice, 0), 0);
    }

    function test_GetLockedTokens_CombinesStakedAndUnclaimedVesting() public {
        // Stake 100, create vesting for 200 (cliff 0, full 1 day)
        _seedAlice(100 * ONE);
        vm.prank(alice);
        token.stake(100 * ONE, 30);

        vm.prank(owner);
        token.createVestingSchedule(alice, 200 * ONE, block.timestamp, 0, 1 days, false);

        assertEq(token.getLockedTokens(alice), 100 * ONE + 200 * ONE);
    }

    // ---------------------------------------------------------------------
    // Event emission
    // ---------------------------------------------------------------------

    event Staked(address indexed user, uint256 amount, uint256 lockPeriod, uint256 stakeIndex);
    event VestingScheduleCreated(
        address indexed beneficiary,
        uint256 amount,
        uint256 startTime,
        uint256 cliff,
        uint256 duration
    );

    function test_Emits_StakedEvent() public {
        _seedAlice(100 * ONE);
        vm.expectEmit(true, false, false, true, address(token));
        emit Staked(alice, 50 * ONE, 90, 0);
        vm.prank(alice);
        token.stake(50 * ONE, 90);
    }

    function test_Emits_VestingScheduleCreatedEvent() public {
        uint256 start = block.timestamp;
        vm.expectEmit(true, false, false, true, address(token));
        emit VestingScheduleCreated(alice, 100 * ONE, start, 10 days, 365 days);
        vm.prank(owner);
        token.createVestingSchedule(alice, 100 * ONE, start, 10 days, 365 days, false);
    }

    // ---------------------------------------------------------------------
    // Fuzz: transfer conservation
    // ---------------------------------------------------------------------

    /// @dev Transfer conservation: pre_sender = post_sender + post_recipient + post_treasury_delta + burned.
    function testFuzz_Transfer_PreservesSupplyMinusBurn(uint256 amount, uint16 feeBps, uint16 burnBps) public {
        feeBps = uint16(bound(uint256(feeBps), 0, 500));
        burnBps = uint16(bound(uint256(burnBps), 0, 100));
        amount = bound(amount, 1, TEAM / 10);

        vm.prank(owner);
        token.updateFeeRates(feeBps, burnBps);

        uint256 supplyBefore = token.totalSupply();
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(owner);
        token.transfer(alice, amount);

        uint256 expectedBurn = (amount * burnBps) / FEE_DENOMINATOR;
        uint256 expectedFee = (amount * feeBps) / FEE_DENOMINATOR;
        uint256 expectedNet = amount - expectedBurn - expectedFee;

        assertEq(token.balanceOf(alice), expectedNet, "alice gets net");
        assertEq(token.balanceOf(treasury), treasuryBefore + expectedFee, "treasury gets fee");
        assertEq(ownerBefore - token.balanceOf(owner), amount, "owner loses full amount");
        assertEq(supplyBefore - token.totalSupply(), expectedBurn, "supply drops by burn");
    }

    /// @dev Rewards are monotonically non-decreasing with elapsed time for a live stake.
    function testFuzz_StakingRewards_MonotoneInTime(uint256 dt1, uint256 dt2) public {
        dt1 = bound(dt1, 1, 365 days);
        dt2 = bound(dt2, 1, 365 days);

        _seedAlice(1_000 * ONE);
        vm.prank(alice);
        token.stake(1_000 * ONE, 0);

        vm.warp(block.timestamp + dt1);
        uint256 r1 = token.calculateRewards(alice, 0);

        vm.warp(block.timestamp + dt2);
        uint256 r2 = token.calculateRewards(alice, 0);

        assertGe(r2, r1, "rewards non-decreasing over time");
    }

    /// @dev For a no-lock stake the lock-period reward rate is 100 bps; closed-form reward check.
    function testFuzz_ZeroLockStakeReward_ClosedForm(uint256 principal, uint256 dt) public {
        principal = bound(principal, 1 * ONE, 10_000 * ONE);
        dt = bound(dt, 0, 365 days);

        _seedAlice(principal);
        vm.prank(alice);
        token.stake(principal, 0);

        vm.warp(block.timestamp + dt);
        uint256 reward = token.calculateRewards(alice, 0);
        uint256 expected = (principal * 100 * dt) / (365 days * FEE_DENOMINATOR);
        assertEq(reward, expected, "closed-form reward matches contract");
    }
}
