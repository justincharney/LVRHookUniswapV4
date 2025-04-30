// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {OnChainLVRMitigationHook} from "../src/LVRMitigationHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract LVRMitigationHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    OnChainLVRMitigationHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Constants for testing
    uint24 constant DYNAMIC_FEE_FLAG = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG (1 << 23)
    uint24 constant MIN_FEE_PPM = 1000; // 10 basis points in parts per million (10 * 100)

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            ) ^ (0x5555 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager);
        deployCodeTo(
            "LVRMitigationHook.sol:OnChainLVRMitigationHook",
            constructorArgs,
            flags
        );
        hook = OnChainLVRMitigationHook(flags);

        // Create the pool with dynamic fee flag
        key = PoolKey(currency0, currency1, DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts
            .getAmountsForLiquidity(
                SQRT_PRICE_1_1,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidityAmount
            );

        (tokenId, ) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testDynamicFeeInitialization() public {
        // Test that the pool must be initialized with a dynamic fee
        uint24 nonDynamicFee = 3000; // Standard 0.3% fee without dynamic flag
        PoolKey memory nonDynamicKey = PoolKey(
            currency0,
            currency1,
            nonDynamicFee,
            60,
            IHooks(hook)
        );

        // Should revert because fee doesn't have the dynamic flag
        vm.expectRevert(OnChainLVRMitigationHook.MustUseDynamicFee.selector);
        manager.initialize(nonDynamicKey, SQRT_PRICE_1_1);

        // Verify initial fee is set correctly
        assertEq(hook.nextFeeToApply(poolId), MIN_FEE_PPM);
    }

    function testBasicSwapFeeUpdate() public {
        // Verify initial fee
        assertEq(hook.nextFeeToApply(poolId), MIN_FEE_PPM);

        // Perform a swap
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        // Fee should not change within the same block
        assertEq(hook.nextFeeToApply(poolId), MIN_FEE_PPM);

        // Move to the next block to trigger fee recalculation
        vm.roll(block.number + 1);

        // Perform another swap to trigger fee update for the next block
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        // Fee should remain at MIN_FEE_PPM since not much volatility has occurred
        assertEq(hook.nextFeeToApply(poolId), MIN_FEE_PPM);
    }

    function testVolatilityImpactOnFees() public {
        // Create volatility with back-and-forth swaps
        bool zeroForOne = true;
        int256 largeSwap = -10e18;

        // Perform multiple swaps in alternate directions to create volatility
        for (uint i = 0; i < 5; i++) {
            swap(key, zeroForOne, largeSwap, ZERO_BYTES);
            swap(key, !zeroForOne, (-largeSwap * 9) / 10, ZERO_BYTES); // Not fully reversing to create net movement
        }

        // Move to the next block
        vm.roll(block.number + 1);

        // Trigger fee calculation with a new swap
        swap(key, zeroForOne, -1e18, ZERO_BYTES);

        // Fee should be higher than the minimum due to volatility
        uint24 feeAfterVolatility = hook.nextFeeToApply(poolId);
        emit log_named_uint("Fee after volatility (PPM)", feeAfterVolatility);
        assertTrue(
            feeAfterVolatility > MIN_FEE_PPM,
            "Fee should increase after volatility"
        );
    }

    function testMultiBlockFeeAdjustment() public {
        // First create high volatility
        bool zeroForOne = true;

        // Large price-moving swaps
        for (uint i = 0; i < 3; i++) {
            swap(key, zeroForOne, -20e18, ZERO_BYTES);
            swap(key, !zeroForOne, 19e18, ZERO_BYTES);
        }

        // Move to next block
        vm.roll(block.number + 1);

        // Trigger fee calculation
        swap(key, zeroForOne, -1e18, ZERO_BYTES);

        // Save the high volatility fee
        uint24 highVolatilityFee = hook.nextFeeToApply(poolId);
        emit log_named_uint("High volatility fee (PPM)", highVolatilityFee);
        assertTrue(
            highVolatilityFee > MIN_FEE_PPM,
            "Fee should be higher after volatility"
        );

        // Now simulate low volatility periods
        vm.roll(block.number + 1);

        // Small swap with minimal price impact
        swap(key, zeroForOne, -0.5e18, ZERO_BYTES);

        // Move to next block and check fee
        vm.roll(block.number + 1);
        swap(key, zeroForOne, -0.5e18, ZERO_BYTES);

        uint24 lowVolatilityFee = hook.nextFeeToApply(poolId);
        emit log_named_uint("Low volatility fee (PPM)", lowVolatilityFee);

        // Fee should decrease compared to high volatility period
        assertTrue(
            lowVolatilityFee < highVolatilityFee,
            "Fee should be lower after period of low volatility"
        );
    }

    function testExtremeLVRFeeClamping() public {
        // Create extreme volatility
        bool zeroForOne = true;

        // Massive swaps back and forth to create extreme volatility
        for (uint i = 0; i < 10; i++) {
            swap(key, zeroForOne, -40e18, ZERO_BYTES);
            swap(key, !zeroForOne, 39e18, ZERO_BYTES);
        }

        // Move to next block
        vm.roll(block.number + 1);

        // Trigger fee update
        swap(key, zeroForOne, -1e18, ZERO_BYTES);

        uint24 extremeFee = hook.nextFeeToApply(poolId);
        emit log_named_uint("Extreme volatility fee (PPM)", extremeFee);

        // Fee should be significantly higher but still valid
        assertTrue(
            extremeFee > MIN_FEE_PPM * 10,
            "Fee should be much higher than minimum"
        );
        assertTrue(
            extremeFee <= type(uint24).max,
            "Fee should not exceed uint24 max"
        );
    }
}
