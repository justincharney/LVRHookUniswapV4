// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  Variance‑adjusted dynamic‑fee hook for Uniswap v4 constant‑product pools
 *  -----------------------------------------------------------------------
 *  ‑   Formula (Constant‑Product pools):  LVR ~ sigma^2/8  of pool value
 *       with  sigma^2 ~ (Δtick * ln(1.0001))^2 / Δt.
 *  -   We charge per‑swap rather than Δt:  fee_micro_bps = ceil(C * Δtick^2)
 *       where  C = (ln(1.0001))^2 / 8 * 1e6 ~ 0.00125
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
    // Fee parameters (all compile‑time constants)
    // ---------------------------------------------------------------------

    uint256 private constant BASE_FEE_MICRO_BPS = 5_000; // 0.05%

    // C ≈ (ln(1.0001))^2 / 8 * 1e6  ≈ 0.0012499…
    // represented as NUM / DEN to stay in uint math
    uint256 private constant C_NUM = 125; // numerator
    uint256 private constant C_DEN = 100_000; // denominator  ⇒ 125/100000 = 0.00125

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
                beforeSwap: true, // Update dynamic fee
                afterSwap: false,
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
    // Before‑swap: estimate the price impact and compute the fee in micro_bps (max fee is 1_000_000 bps)
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
        if (params.amountSpecified >= 0) {
            // exact‑input
            postSqrtX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                preSqrtX96,
                liquidity,
                uint256(params.amountSpecified),
                true
            );
        } else {
            // exact‑output
            postSqrtX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                preSqrtX96,
                liquidity,
                uint256(-params.amountSpecified),
                false
            );
        }

        int24 postTick = TickMath.getTickAtSqrtPrice(postSqrtX96);

        // Δtick^2
        int256 dTick = int256(postTick) - int256(preTick);
        uint256 dTick2 = uint256(dTick * dTick);

        // fee_micro_bps = BASE_FEE_MICRO_BPS + ceil(C_NUM * dTick^2 / C_DEN)
        uint256 fee = BASE_FEE_MICRO_BPS + (dTick2 * C_NUM + C_DEN - 1) / C_DEN; // ceilDiv
        uint24 dynFee = fee > LPFeeLibrary.MAX_LP_FEE
            ? LPFeeLibrary.MAX_LP_FEE
            : uint24(fee);

        // Push to PoolManager so this swap uses the new fee
        // poolManager.updateDynamicLPFee(key, dynFee);

        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynFee | LPFeeLibrary.OVERRIDE_FEE_FLAG // Set the override flag
        );
    }
}
