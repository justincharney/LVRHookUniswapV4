// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Hooks, IHooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {Fixtures} from "./utils/Fixtures.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {OnChainLVRMitigationHook} from "../src/LVRMitigationHook.sol";

contract Replayer is Test, Fixtures {
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
        uint64 blk;
        int128 amount0; // raw swap deltas (already returned by PoolSwapTest::swap)
        int128 amount1;
        uint24 feePpmApplied; // value your hook returned (after removing flag)
        uint256 feeGrowth0X128; // cumulative LP-fees after swap
        uint256 feeGrowth1X128;
        uint256 varianceSumSq; // v.sumSq right after the swap
        uint256 excessCaptured; // PPM above the 10 bps floor
    }
    SwapMetrics[] public swaps;

    /* ---------- state ------------------------------------------ */
    OnChainLVRMitigationHook hook;
    PoolKey pkey;
    uint24 constant MIN_FEE_PPM = 1_000;
    uint256 constant Q128 = 2 ** 128;

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
            "LVRMitigationHook.sol:OnChainLVRMitigationHook",
            abi.encode(manager),
            hookAddr
        );
        hook = OnChainLVRMitigationHook(hookAddr);

        /* pool */
        pkey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000, // dynamic-fee
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        manager.initialize(pkey, SQRT_PRICE_1_1);

        /* seed full-range liquidity so swaps succeed */
        int24 low = TickMath.minUsableTick(pkey.tickSpacing);
        int24 high = TickMath.maxUsableTick(pkey.tickSpacing);
        uint128 liq = 1e23;

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
        uint256 prevBlk = block.number;
        for (uint i; i < rswaps.length; ++i) {
            RawSwap memory s = rswaps[i];

            // keep block numbers in-sync so variance/fee evolves realistically
            if (s.blockNumber > prevBlk) {
                vm.roll(s.blockNumber);
                prevBlk = s.blockNumber;
            }

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

            _recordMetrics(delta, s);

            // just sanity-check replay integrity
            emit log_named_int("delta0", delta.amount0());
            emit log_named_int("delta1", delta.amount1());
        }

        // Get the data into an output format
        _logCapturedLVR();
        _writeCsv();

        // optional assertion: final fee is at least the floor
        assertGe(hook.nextFeeToApply(pkey.toId()), MIN_FEE_PPM);
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

    /* ───────────────── INTERNALS ───────────────────────────── */

    function _recordMetrics(BalanceDelta delta, RawSwap memory) internal {
        // fee that *_beforeSwap* decided on
        uint24 feeClean = hook.lastFeeWithFlag() &
            LPFeeLibrary.REMOVE_OVERRIDE_MASK;

        // pool-wide cumulative fee growth (state slot #3/#4)
        (uint256 feeG0, uint256 feeG1) = StateLibrary.getFeeGrowthGlobals(
            manager,
            pkey.toId()
        );

        uint256 sumSq = hook.getSumSq(pkey.toId());

        uint256 absIn = delta.amount0() < 0
            ? uint256(uint128(-delta.amount0()))
            : uint256(uint128(-delta.amount1())); // the token we paid
        uint256 excessPpm = feeClean > MIN_FEE_PPM ? feeClean - MIN_FEE_PPM : 0;

        swaps.push(
            SwapMetrics({
                blk: uint64(block.number),
                amount0: delta.amount0(),
                amount1: delta.amount1(),
                feePpmApplied: feeClean,
                feeGrowth0X128: feeG0,
                feeGrowth1X128: feeG1,
                varianceSumSq: sumSq,
                excessCaptured: (excessPpm * absIn) / 1e6 // token-denominated
            })
        );
    }

    function _logCapturedLVR() internal {
        uint256 total;
        for (uint i; i < swaps.length; ++i) total += swaps[i].excessCaptured;
        emit log_named_uint("Captured-LVR (token-in units)", total);
    }

    function _writeCsv() internal {
        string memory path = "./storage/metrics.csv";
        vm.writeFile(path, "idx,block,feePpm,sumSq\n");
        for (uint i; i < swaps.length; ++i) {
            vm.writeLine(
                path,
                string.concat(
                    vm.toString(i),
                    ",",
                    vm.toString(swaps[i].blk),
                    ",",
                    vm.toString(swaps[i].feePpmApplied),
                    ",",
                    vm.toString(swaps[i].varianceSumSq)
                )
            );
        }
        emit log_string(
            string.concat("CSV written: ", path, "  (ready for Python)")
        );
    }
}
