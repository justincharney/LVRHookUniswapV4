// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;
import "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {VarianceFeeHook} from "../../src/VarianceFeeHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract VarianceFeeHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    VarianceFeeHook internal hook;
    PoolKey internal poolKey;
    PoolId internal poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    uint24 internal constant BASE_FEE = 5000; // 0.05 % micro‑bps

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
            ) ^ (0x4444 << 144)
        );

        bytes memory ctorArgs = abi.encode(manager);
        deployCodeTo(
            "VarianceFeeHook.sol:VarianceFeeHook",
            ctorArgs,
            hookAddress
        );

        hook = VarianceFeeHook(hookAddress);

        /* 3. create a dynamic-fee pool that uses the hook                */
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        // price 1 : 1
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        /* 4. add a small full-range LP position so swaps succeed         */
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // provide initial liquidity: 100 token0 + 100 token1 wide range
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

    /* --------------------------------------------------------------------
       Helper – compute expected dynamic fee micro‑bps from Δtick
    -------------------------------------------------------------------- */
    function feeFromDelta(int256 dtick) internal pure returns (uint24) {
        uint256 abs2 = uint256(dtick * dtick);
        uint256 fee = BASE_FEE + (abs2 * 125 + 100_000 - 1) / 100_000; // ceilDiv
        if (fee > LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE;
        return uint24(fee);
    }

    /* --------------------------------------------------------------------
       1. Small exact‑input swap stays in‑tick: fee matches formula
    -------------------------------------------------------------------- */
    function testFeeExactInputSmall() public {
        BalanceDelta delta;
        int256 SWAP = -0.1e18;

        // Get the tick before the swap
        (, int24 beforeTick, , ) = manager.getSlot0(poolId);

        // Perform the swap
        // This should be within a tick so we don't over/under charge
        // Exact‑input swap 0.1 token0 -> token1, zeroForOne = true
        delta = swap(poolKey, true, SWAP, ZERO_BYTES);

        // Get the tick after the swap
        (, int24 afterTick, , ) = manager.getSlot0(poolId);

        uint24 expectedFee = feeFromDelta(
            int256(afterTick) - int256(beforeTick)
        );
        (, , , uint24 lpFee) = manager.getSlot0(poolId);

        assertEq(
            lpFee,
            expectedFee,
            "dynamic fee should equal sigma^2/8 formula"
        );
    }

    /* --------------------------------------------------------------------
       2. Fee reconciliation: error from swap‑1 should be in the "carry"
    -------------------------------------------------------------------- */
    function testCarryReconciliation() public {
        // Craft a swap the we incorrectly quote
        BalanceDelta delta;
        int256 SWAP = 3e18;

        // record tick before swap
        (, int24 beforeTick, , ) = manager.getSlot0(poolId);

        // Perform the swap
        delta = swap(poolKey, true, SWAP, ZERO_BYTES);

        // Get the tick after the swap
        (, int24 afterTick, , ) = manager.getSlot0(poolId);

        // Calculate what the fee should have been
        uint24 expectedFee = feeFromDelta(
            int256(afterTick) - int256(beforeTick)
        );

        // Get the fee after the swap
        (, , , uint24 lpFee) = manager.getSlot0(poolId);

        // Get the carry from the swap (fee error)
        int24 carryAmount = hook.getPred(poolId).carry;

        // Assert that the fee + carry (could be +/-) is the expected fee
        assertEq(
            int256(uint256(lpFee)) + int256(carryAmount),
            int256(uint256(expectedFee)),
            "swap fee + carry should equal the expected fee (sigma^2/8)"
        );
    }
}
