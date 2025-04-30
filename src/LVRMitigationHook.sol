// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

// Uniswap v4 core library reference
// https://docs.uniswap.org/contracts/v4/reference/core/libraries/LPFeeLibrary

contract OnChainLVRMitigationHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    error MustUseDynamicFee();

    // Define constants
    // ln(1.0001) using Q64 format, right shifted by 24 bits to be effectively << 40
    // THIS IS SOMEHOW RELATED TO TickMath lib, but I don't know how
    uint256 private constant LN_1_0001_Q40 = 109_945_666; // 0.000099995 * 2^40
    // minimum fee (basis-points = 1e-2 %) you are willing to charge
    uint256 private constant MIN_FEE_BPS = 10; // 10 basis points (0.1%)

    // fee = MIN_FEE + GAMMA · VARIANCE/8 - tune γ with the two numbers below
    // uint256 private constant GAMMA_NUM = 5_000; // numerator
    // uint256 private constant GAMMA_DEN = 1e18; // denominator

    // Store the state of the pool
    struct VolAcc {
        int24 lastTick;
        uint256 sumSq; // sum of the delta_tick^2 in the block defined by lastBlock
        uint32 lastBlock;
    }

    // Mapping from PoolId to its volatility accumulator state
    mapping(PoolId => VolAcc) internal volAccs;

    constructor(IPoolManager _pm) BaseHook(_pm) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true, // check for dynamic fee flag
                afterInitialize: false, // (initial state set in after swap)
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true, // Accumulate variance, update fee proactively on block rollover
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @inheritdoc IHooks
    function beforeInitialize(
        address, // sender
        PoolKey calldata key,
        uint160 // sqrtPriceX96
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address, // sender
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta
    ) external override returns (bytes4) {
        // Initialize accumulator for the current block
        PoolId poolId = key.toId();
        VolAcc storage v = volAccs[poolId];
        uint32 currentBlk = uint32(block.number);

        // Get the tick after the swap from the poolManager
        // https://docs.uniswap.org/contracts/v4/guides/read-pool-state#getslot0
        (, int24 tickAfter, , ) = StateLibrary.getSlot0(poolManager, poolId);

        // First event we ever see for this pool? Initialize...
        if (v.lastBlock == 0) {
            v.lastBlock = currentBlk;
            v.lastTick = tickAfter;
            return IHooks.afterSwap.selector;
        }

        // Same block? accumulate realised variance
        if (currentBlk == v.lastBlock) {
            // Calculate tick change since last swap in this block
            int256 dTick = int256(tickAfter) - int256(v.lastTick);
            // Accumulate variance
            v.sumSq += uint256(dTick * dTick);
            // Update the lastTick
            v.lastTick = tickAfter;
            return IHooks.afterSwap.selector;
        }

        // New block
        // Convert the sum of delta_tick^2 into variance and update the fee
        if (v.lastBlock < currentBlk) {
            // Finalize variance from the PREVIOUS block
            // varLastBlock = sum(delta_tick)^2 * (LN_1_0001_Q40 * LN_1_0001_Q40) >> (2*40)
            uint256 sigma2_Q40 = (v.sumSq * (LN_1_0001_Q40 * LN_1_0001_Q40)) >>
                (2 * 40);

            // Convert to BPS and take 95% of LVR (variance/8)
            uint256 var8_bps = (10_000 * sigma2_Q40) / 8;
            // Adjust the fraction to get the desired amount of LVR as a fee increase
            uint256 extraCost = (var8_bps * 95) / 100;
            // Fee = MIN_FEE_BPS + extraCost
            uint256 dynFee = MIN_FEE_BPS + extraCost;

            // Covert Total fee from BPS to PPM
            uint256 feePPM_unclamped = dynFee * 100; // 1 BPS = 100 PPM

            // Clamp using PPM values
            uint24 fee;
            uint24 MIN_FEE_PPM = uint24(MIN_FEE_BPS * 100); // Define min PPM

            if (feePPM_unclamped < MIN_FEE_PPM) {
                // Check against min PPM
                fee = MIN_FEE_PPM;
            } else {
                // Final check against uint24 max for the PPM value
                if (feePPM_unclamped > type(uint24).max) {
                    fee = type(uint24).max;
                } else {
                    fee = uint24(feePPM_unclamped);
                }
            }

            // Update the fee for the pool
            poolManager.updateDynamicLPFee(key, fee);

            // Reset accumulator for the new block
            v.sumSq = 0;
            v.lastBlock = currentBlk;
            v.lastTick = tickAfter;

            return IHooks.afterSwap.selector;
        }

        return IHooks.afterSwap.selector;
    }
}
