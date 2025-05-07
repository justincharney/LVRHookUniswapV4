// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Hooks, IHooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {Fixtures} from "./utils/Fixtures.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {VarianceFeeHook} from "../src/VarianceFeeHook.sol";

contract ReplaySwaps is Test, Fixtures {
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using stdJson for string;
    using StateLibrary for IPoolManager;

    /* ---------- swap struct that matches the JSON -------------- */
    struct RawSwap {
        string amount0;
        string amount1;
        uint160 sqrtPriceX96;
        uint256 blockNumber;
    }

    /* ---------- Metrics from the swaps -------------- */
    struct SwapMetrics {
        int128 amount0;
        int128 amount1;
        uint160 sqrtPriceBefore;
        uint160 sqrtPriceAfter;
        int24 tickBefore;
        int24 tickAfter;
        uint24 expectedFee;
        uint24 actualFee;
        int24 carry;
    }
    SwapMetrics[] public swaps;

    /* ---------- state ------------------------------------------ */
    VarianceFeeHook hook;
    PoolKey internal pkey;
    PoolId internal poolId;
    uint24 internal constant BASE_FEE = 500; // 0.05% in micro-bps

    /* ---------- set-up ----------------------------------------- */
    function setUp() public {
        /* infra & tokens */
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        /* hook at a pre-flagged address */
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "VarianceFeeHook.sol:VarianceFeeHook",
            abi.encode(manager),
            hookAddr
        );
        hook = VarianceFeeHook(hookAddr);

        /* pool */
        pkey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10, // NEED TO VERIFY THIS
            hooks: IHooks(hook)
        });
        poolId = pkey.toId();
        manager.initialize(pkey, SQRT_PRICE_1_1);

        /* seed full-range liquidity so swaps succeed */
        int24 low = TickMath.minUsableTick(pkey.tickSpacing);
        int24 high = TickMath.maxUsableTick(pkey.tickSpacing);
        uint128 liq = 10000e18; // Initialize with 10_000 of each token

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(low),
            TickMath.getSqrtPriceAtTick(high),
            liq
        );
        posm.mint(
            pkey,
            low,
            high,
            liq,
            a0 + 1,
            a1 + 1,
            address(this),
            block.timestamp,
            ""
        );
    }

    /* ---------- the actual replay test ------------------------- */
    function test_replaySwaps() public {
        /* 1. read file */
        string memory json = vm.readFile("./swaps.json");

        bytes memory arr = json.parseRaw(".data.pool.swaps"); // returns the ABI-encoded array
        RawSwap[] memory rswaps = abi.decode(arr, (RawSwap[]));

        /* 2. loop over them */
        for (uint i; i < rswaps.length; ++i) {
            RawSwap memory s = rswaps[i];

            // Save pre-swap state
            (uint160 preSqrtPrice, int24 preTick, , ) = manager.getSlot0(
                poolId
            );

            // Parse amounts from JSON.
            // amount0 is USDC (6 dec), amount1 is WETH (18 dec)
            int256 amount0 = _stringToFixed(s.amount0, 6);
            int256 amount1 = _stringToFixed(s.amount1, 18);

            bool zeroForOne; // True if swapping USDC for WETH (selling currency0)
            int256 amountSpecified;
            // If `amount0 < 0`: This means token0 was **removed** from the pool.
            // From the swapper's perspective, they **received** (or bought) token0.
            if (amount0 < 0) {
                // Selling token1, receiving token0
                zeroForOne = false;
                amountSpecified = amount1;
            } else {
                // Selling token0, receiving token1
                zeroForOne = true;
                amountSpecified = amount0;
            }

            // run swap through the standard helper from Fixtures
            BalanceDelta delta = swap(
                pkey,
                zeroForOne,
                amountSpecified,
                ZERO_BYTES // no hook data
            );

            _recordMetrics(delta, preSqrtPrice, preTick);
        }

        // Get the data into an output format
        _writeCsv();
    }

    /* ---------- helpers ---------------------------------------- */

    function _stringToFixed(
        string memory s,
        uint8 targetDecimals
    ) internal pure returns (int256) {
        bytes memory b = bytes(s);
        if (b.length == 0) return 0;

        bool negative = false;
        uint ptr = 0;
        if (b[ptr] == "-") {
            negative = true;
            ptr++;
        } else if (b[ptr] == "+") {
            ptr++;
        }

        uint256 intPart = 0;
        uint256 fracPart = 0;
        uint8 fracDigits = 0;
        bool inFraction = false;

        for (uint i = ptr; i < b.length; i++) {
            if (b[i] == ".") {
                if (inFraction) break;
                inFraction = true;
                continue;
            }
            if (b[i] < "0" || b[i] > "9") break;

            uint8 digit = uint8(b[i]) - 48;
            if (inFraction) {
                if (fracDigits < targetDecimals) {
                    // Read up to targetDecimals
                    fracPart = fracPart * 10 + digit;
                    fracDigits++;
                } else if (fracDigits < 18) {
                    // if target is < 18, but more are provided, just count them
                    fracDigits++; // to correctly scale down later if target < actual
                }
            } else {
                intPart = intPart * 10 + digit;
            }
        }

        uint256 scaledValue = intPart * (10 ** targetDecimals);

        if (fracDigits > 0) {
            if (fracDigits < targetDecimals) {
                fracPart *= (10 ** (targetDecimals - fracDigits));
            } else if (fracDigits > targetDecimals) {
                // If more fractional digits were provided than target, truncate/round down
                fracPart /= (10 ** (fracDigits - targetDecimals));
            }
            scaledValue += fracPart;
        }

        int256 result = int256(scaledValue);
        return negative ? -result : result;
    }

    function feeFromDelta(int256 dtick) internal pure returns (uint24) {
        uint256 abs2 = uint256(dtick * dtick);
        uint256 fee = BASE_FEE + (abs2 * 125 + 100_000 - 1) / 100_000; // ceilDiv
        if (fee > LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE;
        return uint24(fee);
    }

    /* ───────────────── INTERNALS ───────────────────────────── */

    function _recordMetrics(
        BalanceDelta delta,
        uint160 preSqrtPrice,
        int24 preTick
    ) internal {
        // Get current state (post-swap)
        (uint160 postSqrtPrice, int24 postTick, , uint24 postFee) = manager
            .getSlot0(poolId);

        // Get the expected fee (what it should have been based on the delta ticks)
        uint24 expectedFee = feeFromDelta(int256(postTick) - int256(preTick));

        // Carry (fee error between expected and actual)
        int24 carry = hook.getPred(poolId).carry;

        swaps.push(
            SwapMetrics({
                amount0: delta.amount0(),
                amount1: delta.amount1(),
                sqrtPriceBefore: preSqrtPrice,
                sqrtPriceAfter: postSqrtPrice,
                tickBefore: preTick,
                tickAfter: postTick,
                expectedFee: expectedFee,
                actualFee: postFee,
                carry: carry
            })
        );
    }

    function _writeCsv() internal {
        string memory path = "./storage/metrics.csv";
        vm.writeFile(path, "idx,expected_fee,actual_fee,carry\n");
        for (uint i; i < swaps.length; ++i) {
            vm.writeLine(
                path,
                string.concat(
                    vm.toString(i),
                    ",",
                    vm.toString(swaps[i].expectedFee),
                    ",",
                    vm.toString(swaps[i].actualFee),
                    ",",
                    vm.toString(swaps[i].carry)
                )
            );
        }
        emit log_string(
            string.concat("CSV written: ", path, "  (ready for Python)")
        );
    }
}
