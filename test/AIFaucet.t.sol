// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Test} from "forge-std/Test.sol";
import {AIFaucet} from "../src/AIFaucet.sol";
import {AIToken} from "../src/AIToken.sol";

/**
 * @title AIFaucet Foundry Test Suite
 * @notice Behaviour coverage for the per-address rate-limited faucet.
 *
 * Covers:
 *  - Drip flow happy-path and event emission.
 *  - Cooldown enforcement per address.
 *  - Daily cap enforcement per address (rolls over once block.timestamp / 1 days increments).
 *  - canDrip() and timeUntilNextDrip() view consistency with drip() state transitions.
 *  - Config update: validation, event, onlyOwner gating.
 *  - Pause blocks drip; unpause restores.
 *  - emergencyWithdraw: onlyOwner, token and native paths.
 *  - Balance / refill bookkeeping.
 *  - Fuzz: total tokens dripped to a user in one day never exceeds maxDailyLimit.
 */
contract AIFaucetTest is Test {
    AIToken internal token;
    AIFaucet internal faucet;

    address internal owner = address(0xA11CE);
    address internal treasury = address(0xB0B);
    address internal alice = address(0xA71);
    address internal bob = address(0xB71);

    uint256 internal constant ONE = 1e18;
    uint256 internal constant DRIP = 100 * 1e18;
    uint256 internal constant COOLDOWN = 1 hours;
    uint256 internal constant DAILY = 500 * 1e18;

    function setUp() public {
        vm.startPrank(owner);
        token = new AIToken(treasury);
        faucet = new AIFaucet(address(token), DRIP, COOLDOWN, DAILY);

        // Fund the faucet from owner's TEAM tranche. Transfers trigger 0.1% burn, but for
        // faucet funding a slight over-send is fine — we just need enough reserve.
        token.transfer(address(faucet), 10_000 * ONE);
        vm.stopPrank();

        // Start beyond day 0 so daily bucket math doesn't underflow around genesis.
        vm.warp(1_700_000_000);
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    function test_Constructor_StoresConfig() public {
        assertEq(address(faucet.aiToken()), address(token));
        assertEq(faucet.dripAmount(), DRIP);
        assertEq(faucet.cooldownPeriod(), COOLDOWN);
        assertEq(faucet.maxDailyLimit(), DAILY);
        assertEq(faucet.owner(), owner);
    }

    // ---------------------------------------------------------------------
    // Drip happy path
    // ---------------------------------------------------------------------

    event Drip(address indexed recipient, uint256 amount);

    function test_Drip_TransfersTokensAndEmits() public {
        uint256 balBefore = token.balanceOf(alice);

        vm.expectEmit(true, false, false, true, address(faucet));
        emit Drip(alice, DRIP);

        vm.prank(alice);
        faucet.drip();

        assertEq(token.balanceOf(alice) - balBefore, DRIP, "alice receives exactly DRIP");
        assertEq(faucet.lastDripTime(alice), block.timestamp);
    }

    function test_Drip_RevertsWhenCooldownActive() public {
        vm.prank(alice);
        faucet.drip();

        vm.prank(alice);
        vm.expectRevert(bytes("Cooldown period not elapsed or daily limit reached"));
        faucet.drip();
    }

    function test_Drip_SucceedsAfterCooldown() public {
        vm.prank(alice);
        faucet.drip();

        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.prank(alice);
        faucet.drip();

        assertEq(token.balanceOf(alice), DRIP * 2);
    }

    function test_Drip_RevertsWhenDailyLimitReached() public {
        // DAILY / DRIP = 5. Drip 5 times inside one day (advancing only by cooldown).
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            faucet.drip();
            vm.warp(block.timestamp + COOLDOWN + 1);
        }

        vm.prank(alice);
        vm.expectRevert(bytes("Cooldown period not elapsed or daily limit reached"));
        faucet.drip();
    }

    function test_Drip_DailyCounterResetsNextDay() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            faucet.drip();
            vm.warp(block.timestamp + COOLDOWN + 1);
        }
        // Jump to next day bucket
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        faucet.drip();
        // 6th successful drip -> balance = 6 * DRIP
        assertEq(token.balanceOf(alice), 6 * DRIP);
    }

    // ---------------------------------------------------------------------
    // View invariants
    // ---------------------------------------------------------------------

    function test_CanDrip_FreshUserIsTrue() public {
        assertTrue(faucet.canDrip(bob));
    }

    function test_CanDrip_FalseDuringCooldown() public {
        vm.prank(alice);
        faucet.drip();
        assertFalse(faucet.canDrip(alice));
    }

    function test_TimeUntilNextDrip_ZeroForFreshUser() public {
        assertEq(faucet.timeUntilNextDrip(bob), 0);
    }

    function test_TimeUntilNextDrip_ApproachesZeroAsCooldownExpires() public {
        vm.prank(alice);
        faucet.drip();

        uint256 t1 = faucet.timeUntilNextDrip(alice);
        vm.warp(block.timestamp + COOLDOWN / 2);
        uint256 t2 = faucet.timeUntilNextDrip(alice);
        assertLt(t2, t1, "time until next drip strictly decreases");

        vm.warp(block.timestamp + COOLDOWN);
        assertEq(faucet.timeUntilNextDrip(alice), 0, "zero once past cooldown");
    }

    function test_RemainingDailyLimit_FreshUserIsFullLimit() public {
        assertEq(faucet.remainingDailyLimit(bob), DAILY);
    }

    function test_RemainingDailyLimit_DecreasesAfterDrip() public {
        vm.prank(alice);
        faucet.drip();
        assertEq(faucet.remainingDailyLimit(alice), DAILY - DRIP);
    }

    // ---------------------------------------------------------------------
    // Config
    // ---------------------------------------------------------------------

    event ConfigUpdate(uint256 dripAmount, uint256 cooldownPeriod, uint256 maxDailyLimit);

    function test_UpdateConfig_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        faucet.updateConfig(1, 1, 1);
    }

    function test_UpdateConfig_RevertsOnZeroDrip() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Drip amount must be positive"));
        faucet.updateConfig(0, COOLDOWN, DAILY);
    }

    function test_UpdateConfig_RevertsOnZeroCooldown() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Cooldown must be positive"));
        faucet.updateConfig(DRIP, 0, DAILY);
    }

    function test_UpdateConfig_RevertsOnLimitBelowDrip() public {
        vm.prank(owner);
        vm.expectRevert(bytes("Daily limit must be >= drip amount"));
        faucet.updateConfig(200 * ONE, COOLDOWN, 100 * ONE);
    }

    function test_UpdateConfig_Succeeds_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(faucet));
        emit ConfigUpdate(50 * ONE, 2 hours, 1_000 * ONE);
        vm.prank(owner);
        faucet.updateConfig(50 * ONE, 2 hours, 1_000 * ONE);
        assertEq(faucet.dripAmount(), 50 * ONE);
        assertEq(faucet.cooldownPeriod(), 2 hours);
        assertEq(faucet.maxDailyLimit(), 1_000 * ONE);
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function test_Pause_BlocksDrip() public {
        vm.prank(owner);
        faucet.pause();
        vm.prank(alice);
        vm.expectRevert(); // Pausable's EnforcedPause()
        faucet.drip();
    }

    function test_Unpause_RestoresDrip() public {
        vm.startPrank(owner);
        faucet.pause();
        faucet.unpause();
        vm.stopPrank();

        vm.prank(alice);
        faucet.drip();
        assertEq(token.balanceOf(alice), DRIP);
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        faucet.pause();
    }

    // ---------------------------------------------------------------------
    // Emergency withdraw
    // ---------------------------------------------------------------------

    function test_EmergencyWithdraw_Token_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        faucet.emergencyWithdraw(address(token), 1);
    }

    function test_EmergencyWithdraw_TransfersTokensToOwner() public {
        uint256 balBefore = token.balanceOf(owner);
        uint256 faucetBal = token.balanceOf(address(faucet));

        vm.prank(owner);
        faucet.emergencyWithdraw(address(token), faucetBal);

        // internal transfer from contract -> owner is burn-exempt per AIToken._update
        assertEq(token.balanceOf(owner) - balBefore, faucetBal);
    }

    function test_EmergencyWithdraw_NativePath() public {
        // Fund faucet with 1 ether
        vm.deal(address(faucet), 1 ether);
        uint256 ownerBal = owner.balance;

        vm.prank(owner);
        faucet.emergencyWithdraw(address(0), 1 ether);

        assertEq(owner.balance - ownerBal, 1 ether);
    }

    // ---------------------------------------------------------------------
    // Refill
    // ---------------------------------------------------------------------

    event FaucetRefill(uint256 amount);

    function test_Refill_AccountsForBurnOnInboundTransfer() public {
        // AIToken applies 0.1% burn on external transfers — so refill(100) lands as 99.9
        // in the faucet. This test pins the observed behaviour. If the token's fee model
        // changes, this will catch it.
        uint256 amount = 1_000 * ONE;
        vm.prank(owner);
        token.approve(address(faucet), amount);

        uint256 faucetBalBefore = token.balanceOf(address(faucet));

        vm.expectEmit(false, false, false, true, address(faucet));
        emit FaucetRefill(amount);

        vm.prank(owner);
        faucet.refill(amount);

        uint256 expectedDelta = amount - (amount * 10) / 10_000;
        assertEq(token.balanceOf(address(faucet)) - faucetBalBefore, expectedDelta);
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// @dev Across any dripping schedule inside a single day, total dripped to one user
    ///      never exceeds maxDailyLimit.
    function testFuzz_DailyDripNeverExceedsLimit(uint8 attempts, uint16 spacingSec) public {
        attempts = uint8(bound(uint256(attempts), 1, 50));
        // 1 second min spacing to avoid same-timestamp reverts
        spacingSec = uint16(bound(uint256(spacingSec), 1, 3 hours));

        uint256 startDay = block.timestamp / 1 days;
        uint256 totalDripped = 0;

        for (uint256 i = 0; i < attempts; i++) {
            uint256 nextDay = block.timestamp / 1 days;
            if (nextDay != startDay) break; // only count within one day bucket

            vm.warp(block.timestamp + spacingSec);
            vm.prank(alice);
            try faucet.drip() {
                totalDripped += DRIP;
            } catch {
                // expected when cooldown/daily-cap blocks
            }
        }

        assertLe(totalDripped, DAILY, "daily drip total bounded by maxDailyLimit");
    }
}
