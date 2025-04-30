// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* ───────────────────  project utilities / fixtures  ─────────────────── */
import {Fixtures} from "./utils/Fixtures.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";

/* ───────────────────────  the hook under test  ──────────────────────── */
import {OnChainLVRMitigationHook} from "../src/LVRMitigationHook.sol";

/// @dev  10 bp × 100 = 1 000 ppm – must match the constant in the hook.
uint24 constant MIN_FEE_PPM = 1_000;

contract LVRMitigationHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /* ------------------------------------------------------------------ */
    /*                              state                                 */
    /* ------------------------------------------------------------------ */

    OnChainLVRMitigationHook hook;
    PoolKey poolKey;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    /* ------------------------------------------------------------------ */
    /*                               set-up                               */
    /* ------------------------------------------------------------------ */

    function setUp() public {
        /* 1. create a fresh manager + helper routers + two ERC-20s */
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        /* 2. deploy the hook at an address that carries the needed flags */
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144) // namespace to avoid collisions
        );

        bytes memory ctorArgs = abi.encode(manager);
        deployCodeTo(
            "LVRMitigationHook.sol:OnChainLVRMitigationHook",
            ctorArgs,
            hookAddress
        );

        hook = OnChainLVRMitigationHook(hookAddress);

        /* 3. create a dynamic-fee pool that uses the hook                */
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000, // dynamic-fee flag only
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        // price 1 : 1
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        /* 4. add a small full-range LP position so swaps succeed         */
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liq = 100e18;
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liq
        );

        (tokenId, ) = posm.mint(
            poolKey,
            tickLower,
            tickUpper,
            liq,
            amt0 + 1,
            amt1 + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    /* ------------------------------------------------------------------ */
    /*                               tests                                */
    /* ------------------------------------------------------------------ */

    /// The hook records the minimum fee right after initialise.
    function testInitialFeeIsMin() public view {
        assertEq(hook.nextFeeToApply(poolId), MIN_FEE_PPM);
    }

    /// After ≥2 swaps in one block and the first swap in the *next*
    /// block, the hook must have raised nextFeeToApply above the minimum.
    function testFeeIncreasesAfterVariance() public {
        // -------- block N ------------------------------------------------
        BalanceDelta delta;
        int256 SWAP = -2e18;

        delta = swap(poolKey, true, SWAP, ZERO_BYTES); // swap #1
        delta = swap(poolKey, true, SWAP, ZERO_BYTES); // swap #2 – now Σ(Δtick²)>0
        assertEq(
            hook.nextFeeToApply(poolId),
            MIN_FEE_PPM,
            "still min in same block"
        );

        // -------- block N+1 ---------------------------------------------
        uint256 blk = block.number;
        vm.roll(blk + 1); // advance one block

        delta = swap(poolKey, true, -1e18, ZERO_BYTES); // first swap of new block
        uint24 newFee = hook.nextFeeToApply(poolId);

        assertGt(newFee, MIN_FEE_PPM);
        assertLe(newFee, type(uint24).max);
    }

    /// A zero-variance block should *not* raise the fee.
    function testFeeStaysFlatWithoutVariance() public {
        // do exactly one swap in block N → variance accumulator stays zero
        swap(poolKey, true, -1e18, ZERO_BYTES);

        vm.roll(block.number + 1);
        swap(poolKey, true, -1e18, ZERO_BYTES);

        // fee should still be minimum (1 000 ppm)
        assertEq(hook.nextFeeToApply(poolId), MIN_FEE_PPM);
    }
}
