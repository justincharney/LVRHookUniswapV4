// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./LVRMitigationHook.t.sol";

contract LVRMitigationHookDecayTest is LVRMitigationHookTest {
    /// The fees should go back to the base fees after a few blocks of small trades
    uint8 constant DECAY_BLOCKS = 5;

    /// A single whale-trade must raise the fee, and several quiet
    /// blocks afterwards must bring it back to the minimum.
    function testFeeDecaysBackToFloor() public {
        /* ----------------------------------  block N  ----------------- */
        // do a large swap so we certainly cross many ticks
        swap(poolKey, true, -10e18, ZERO_BYTES);

        /* --------------------------------  block N+1  ----------------- */
        vm.roll(block.number + 1);
        // any swap triggers _afterSwap() so the fee for this block
        // is computed from last block’s variance
        swap(poolKey, true, -1e18, ZERO_BYTES);

        uint24 feeAfterShock = hook.nextFeeToApply(poolId);
        assertGt(feeAfterShock, MIN_FEE_PPM);

        /* ---------------  N+2 … N+2+DECAY_BLOCKS-1  ------------------- */
        uint24 previous = feeAfterShock;

        for (uint8 i; i < DECAY_BLOCKS; ++i) {
            vm.roll(block.number + 1);

            // A tiny trade (1/10th of a coin) that is very unlikely to change the tick.
            // (We still need a trade, because the hook only recalculates
            //  at _afterSwap().)
            swap(poolKey, true, -0.1e18, ZERO_BYTES);

            uint24 nowFee = hook.nextFeeToApply(poolId);

            // The fee must never rise in a ~zero-variance block
            assertLe(nowFee, previous, "fee should decay or stay flat");
            previous = nowFee;
        }

        // Eventually we are back at the floor
        assertEq(previous, MIN_FEE_PPM, "fee must settle at the floor");
    }
}
