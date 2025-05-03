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
    uint24 internal constant BASE_FEE = 5000; // 0.05% in micro-bps

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

            (int256 amount0, int256 amount1) = _castAmounts(
                s.amount0,
                s.amount1
            );

            bool zeroForOne;
            int256 amountSpecified;
            if (amount0 < 0) {
                zeroForOne = true; // selling token0, receiving token1
                amountSpecified = amount0; // exact-in
            } else {
                zeroForOne = false;
                amountSpecified = amount1; // token1 exact-in
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

    /// converts a signed decimal string (e.g. "-1084.515284")
    /// to a signed 18-dec fixed-point int (e.g. -1084515284000000000000)
    function _toSignedFixed18(string memory s) internal pure returns (int256) {
        bytes memory b = bytes(s);
        bool neg;
        uint256 intPart;
        uint256 fracPart;
        uint8 fracLen;

        for (uint i; i < b.length; ++i) {
            bytes1 c = b[i];

            if (c == "-") {
                neg = true;
            } else if (c == ".") {
                fracLen = 1; // start counting decimals > 0 means “we’re inside the fraction”
            } else {
                uint8 d = uint8(c) - 48; // ascii → 0-9
                if (fracLen == 0) {
                    intPart = intPart * 10 + d;
                } else if (fracLen <= 18) {
                    // keep at most 18 dp
                    fracPart = fracPart * 10 + d;
                    ++fracLen;
                }
            }
        }

        // left-pad the fraction to 18 dp
        while (fracLen++ < 19) fracPart *= 10;

        int256 fixed18 = int256(intPart * 1e18 + fracPart);
        return neg ? -fixed18 : fixed18;
    }

    function _castAmounts(
        string memory a0,
        string memory a1
    ) internal pure returns (int256 amt0, int256 amt1) {
        amt0 = _toSignedFixed18(a0);
        amt1 = _toSignedFixed18(a1);
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
