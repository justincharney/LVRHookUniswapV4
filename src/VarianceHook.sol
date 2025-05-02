// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  Variance‑adjusted dynamic‑fee hook for Uniswap v4 constant‑product pools
 *  -----------------------------------------------------------------------
 *  ‑   Charges a fee that scales with the price impact that the current
 *      swap will cause, so the trade that realises LVR also pays for it.
 *  ‑   Keeps only 32 bytes of persistent state (last tick + timestamp).
 *  ‑   Uses a transient mapping in memory (pendingFee) to pass the per‑swap
 *      dynamic component from `beforeSwap` -> `getFee` -> `afterSwap`.
 */

import {BaseHook, PoolKey, IPoolManager, BalanceDelta} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/// Hook that makes every swap pay ~ sigma^2/8 of the value it moves (expected LVR)
contract VarianceFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    error MustUseDynamicFee();

    // ---------------------------------------------------------------------
    // Types & storage
    // ---------------------------------------------------------------------
    struct Obs {
        int24 tick;
        uint64 ts;
    }

    mapping(PoolId => Obs) public last;

    // ---------------------------------------------------------------------
    // Fee parameters (all compile‑time constants)
    // ---------------------------------------------------------------------

    // ln(1.0001) in Q128 (2‑128 fixed‑point)
    uint256 private constant LN1_0001_X128 = 0x0171d1eccedc59;

    // gamma = (ln1.0001)^2 / 8  (same units)  —  scales sigma^2 into LVR fraction
    uint256 private constant GAMMA_X128 = (LN1_0001_X128 * LN1_0001_X128) / 8;

    // scaling
    uint256 private constant ONE_MICRO_BIP_X128 = (1e6) << 128; // 1e‑6 * 2^128

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IPoolManager _pm) BaseHook(_pm) {}

    // ---------------------------------------------------------------------
    // Set Hook permissions
    // ---------------------------------------------------------------------

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true, // check for dynamic fee flag
                afterInitialize: false,
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

    // ---------------------------------------------------------------------
    // Before‑initalize: check for the dynamic fee flag on the pool
    // ---------------------------------------------------------------------

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return BaseHook.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------------
    // Before‑swap: estimate the price impact and cache dynamic fee
    // ---------------------------------------------------------------------
    function _beforeSwap(
        address /*sender*/,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /* hookData */
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();

        // ── snapshot pre‑swap state ──────────────────────────────────────
        (uint160 preSqrtX96, int24 preTick, , ) = poolManager.getSlot0(id);

        // ── fetch current liquidity ─────────────────────────────────────
        uint128 liquidity = poolManager.getLiquidity(id);

        // ── project post‑swap sqrtPrice using swap parameters ──────────────────
        // If zeroForOne, input is amountSpecified of token0, etc.
        uint160 postSqrtX96;
        if (params.zeroForOne) {
            postSqrtX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                preSqrtX96,
                liquidity,
                uint256(params.amountSpecified),
                true
            );
        } else {
            postSqrtX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                preSqrtX96,
                liquidity,
                uint256(params.amountSpecified),
                false
            );
        }

        int24 postTick = TickMath.getTickAtSqrtPrice(postSqrtX96);

        // ── dynamic component: gamma * (delta_tick)^2  (in Q128) ───────────────────
        int256 dTick = int256(postTick) - int256(preTick);
        uint256 dTick2 = uint256(dTick * dTick);
        uint256 dynFeeX128 = GAMMA_X128 * dTick2; // Q128 LVR fraction

        // convert to micro‑bps (whole numbers) then clamp
        uint256 dynMicroBps = (dynFeeX128 + ONE_MICRO_BIP_X128 - 1) /
            ONE_MICRO_BIP_X128; // ceilDiv
        uint24 dynFee = dynMicroBps > LPFeeLibrary.MAX_LP_FEE
            ? LPFeeLibrary.MAX_LP_FEE
            : uint24(dynMicroBps);

        // Push to PoolManager so this swap uses the new fee
        // poolManager.updateDynamicLPFee(key, dynFee);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynFee
        );
    }

    // ---------------------------------------------------------------------
    // After‑swap: book‑keeping + cleanup
    // ---------------------------------------------------------------------

    function _afterSwap(
        address /*sender*/,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /*params*/,
        BalanceDelta /*delta*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();

        // Store last tick + timestamp for background variance
        (, int24 tick, , ) = poolManager.getSlot0(id);
        last[id] = Obs({tick: tick, ts: uint64(block.timestamp)});

        return (BaseHook.afterSwap.selector, 0);
    }
}
