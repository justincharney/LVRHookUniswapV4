// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

// Uniswap v4 core library reference
// https://docs.uniswap.org/contracts/v4/reference/core/libraries/LPFeeLibrary

contract OnChainLVRMitigationHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    error MustUseDynamicFee();

    event LogNewFee(PoolId poolId, uint256 newFee, uint256 vSumSq);

    // Define constants
    // ln(1.0001) using Q64 format, right shifted by 24 bits to be effectively << 40
    // THIS IS SOMEHOW RELATED TO TickMath lib, but I don't know how
    uint256 private constant LN_1_0001_Q40 = 109_945_666; // 0.000099995 * 2^40
    // minimum fee (basis-points = 1e-2 %) you are willing to charge
    uint256 private constant MIN_FEE_BPS = 10; // 10 basis points (0.1%)
    uint24 private constant MIN_FEE_PPM = uint24(MIN_FEE_BPS * 100);

    uint256 private constant SUMSQ_DIVISOR = 80_000;
    uint256 private constant SURCHARGE_PCT = 95; // 95 % · Sigma^2/8

    // fee = MIN_FEE + GAMMA · VARIANCE/8 - tune γ with the two numbers below
    // uint256 private constant GAMMA_NUM = 5_000; // numerator
    // uint256 private constant GAMMA_DEN = 1e18; // denominator

    // Store the state of the pool
    struct VolAcc {
        int24 tickBefore;
        uint256 sumSq; // sum of the delta_tick^2 in the block defined by lastBlock
        uint32 lastBlock;
    }

    // Mapping from PoolId to its volatility accumulator state
    mapping(PoolId => VolAcc) internal volAccs;

    // Mapping from PoolId to the fee calculated in the previous block's afterSwap, to be applied in the next beforeSwap
    mapping(PoolId => uint24) public nextFeeToApply;

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
                beforeSwap: true,
                afterSwap: true, // Accumulate variance, update fee proactively on block rollover
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal override returns (bytes4) {
        // Ensure the pool is initialized with the dynamic fee flag
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        // Initialize the default fee for the next block
        nextFeeToApply[key.toId()] = MIN_FEE_PPM;
        return BaseHook.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(
        address, // sender
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        // read current tick once, store for after-swap
        (, int24 tick, , ) = poolManager.getSlot0(poolId);
        volAccs[poolId].tickBefore = tick;
        uint24 feeToUse = nextFeeToApply[poolId];

        // Ensure the fee is within the range
        if (feeToUse < MIN_FEE_PPM) {
            feeToUse = MIN_FEE_PPM;
        } else if (feeToUse > type(uint24).max) {
            feeToUse = type(uint24).max;
        }

        uint24 fee = feeToUse | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee
        );
    }

    /// @inheritdoc BaseHook
    function _afterSwap(
        address, // sender
        PoolKey calldata key,
        IPoolManager.SwapParams calldata, // params
        BalanceDelta, // delta
        bytes calldata // hookData
    ) internal override returns (bytes4, int128) {
        // Initialize accumulator for the current block
        PoolId poolId = key.toId();
        VolAcc storage v = volAccs[poolId];
        uint32 currentBlk = uint32(block.number);

        // Get the tick after the swap from the poolManager
        // https://docs.uniswap.org/contracts/v4/guides/read-pool-state#getslot0
        (, int24 tickAfter, , ) = poolManager.getSlot0(poolId);

        // Calculate tick change for this swap
        int256 dTick = int256(tickAfter) - int256(v.tickBefore);
        uint256 dSq = uint256(dTick * dTick);

        // First event we ever see for this pool? Initialize...
        // if (v.lastBlock == 0) {
        //     v.lastBlock = currentBlk;
        //     v.tickBefore = tickAfter;
        //     return (BaseHook.afterSwap.selector, 0);
        // }

        // Did we roll into a new block? Finalize last block
        if (v.lastBlock != 0 && currentBlk > v.lastBlock) {
            // How many bps one unit of sumSq buys
            // Variance ≈ v.sumSq * (ln(1.0001) ** 2)
            // ExtraFee_BPS ≈ (v.sumSq / (8 * 100,000,000)) * 10000
            uint256 varianceNumeratorFactor = SURCHARGE_PCT * 100; // convert to PPM
            uint256 varianceDenominator = SUMSQ_DIVISOR * 100; // convert to PPM
            // Fee = MIN_FEE_PPM + 0.95*variance/8 (this is why we have the 95 above)
            uint256 totalFeeNumerator = (MIN_FEE_PPM * varianceDenominator) +
                (v.sumSq * varianceNumeratorFactor);
            // fee calculation to avoid issue with integer division
            uint256 feePPM_unclamped = totalFeeNumerator / varianceDenominator;

            // Clamp using PPM values
            uint24 fee;
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

            // Set the fee for the next block
            emit LogNewFee(poolId, fee, v.sumSq);
            nextFeeToApply[poolId] = fee;
        }

        // start / continue the accumulator for this block
        if (currentBlk > v.lastBlock) {
            v.sumSq = dSq;
            v.lastBlock = currentBlk;
        } else {
            v.sumSq += dSq;
        }

        // store the tick for the next trade
        v.tickBefore = tickAfter;

        return (BaseHook.afterSwap.selector, 0);
    }
}
