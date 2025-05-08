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
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {Fixtures} from "./utils/Fixtures.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {VarianceFeeHook} from "../src/VarianceFeeHook.sol";

contract ReplayV4Swaps is Test, Fixtures {
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using stdJson for string;
    using StateLibrary for IPoolManager;

    /* ---------- swap struct that matches the JSON -------------- */
    struct RawSwap {
        string amount0;
        string amount1;
        string sqrtPriceX96;
        string tick;
        string blockNumber;
    }

    /* ---------- Metrics from the swaps -------------- */
    struct SwapMetrics {
        int128 amount0;
        int128 amount1;
        uint160 sqrtPriceBefore;
        uint160 sqrtPriceAfter;
        int24 tickBefore;
        int24 tickAfter;
        int24 expectedTickAfter;
        uint24 expectedFee;
        uint24 actualFee;
        int24 carry;
        uint256 expectedUsdcPrice;
        uint256 actualUsdcPrice;
    }
    SwapMetrics[] public swaps;

    struct TickInfoSnapshot {
        int24 tick;
        string liquidityNet;
        string liquidityGross;
    }

    struct BitmapWordSnapshot {
        int16 wordPos;
        string value; // Read as hex string from JSON
    }

    /* ---------- state ------------------------------------------ */
    VarianceFeeHook hook;
    PoolKey internal pkey;
    PoolId internal poolId;
    uint24 internal constant BASE_FEE = 500; // 0.05% in micro-bps
    uint160 constant INIT_SQRT_PRICE = 3927370225299858350344231;
    uint128 constant INIT_LIQ = 1179919373798284;

    // JSON file paths
    string constant TICK_SNAPSHOT_PATH = "./tick_snapshot.json";
    string constant BITMAP_SNAPSHOT_PATH = "./bitmap_snapshot.json";

    TickInfoSnapshot[] public tickInfos;
    BitmapWordSnapshot[] public bitmapWords;

    /* ---------- set-up ----------------------------------------- */
    function setUp() public {
        /* infra & tokens */
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        // Deal initial balances TO THE POOL MANAGER address itself
        // Choose amounts large enough to cover any potential payout during replay
        uint256 dealAmount0 = 1_000_000 ether; // Example: 1 Million WETH
        uint256 dealAmount1 = 500_000_000 * 1e6; // Example: 500 Million USDC
        deal(Currency.unwrap(currency0), address(manager), dealAmount0);
        deal(Currency.unwrap(currency1), address(manager), dealAmount1);

        // deployAndApprovePosm(manager);
        // uint256 big = type(uint128).max; // plenty
        // MockERC20(address(currency0)).mint(address(manager), big);
        // MockERC20(address(currency1)).mint(address(manager), big);

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
            tickSpacing: 10,
            hooks: IHooks(hook)
        });
        poolId = pkey.toId();

        // Initialize Pool - sets initial Slot0 based on INIT_SQRT_PRICE
        manager.initialize(pkey, INIT_SQRT_PRICE);

        // --- 2. Load snapshots from JSON ---
        string memory tickJson = vm.readFile(TICK_SNAPSHOT_PATH);
        string[] memory tickKeys = vm.parseJsonKeys(tickJson, "$");

        for (uint i = 0; i < tickKeys.length; i++) {
            string memory key = tickKeys[i];
            int24 tick = int24(vm.parseInt(key));
            string memory liquidityNet = vm.parseJsonString(
                tickJson,
                string.concat("$.", key, ".liquidityNet")
            );
            string memory liquidityGross = vm.parseJsonString(
                tickJson,
                string.concat("$.", key, ".liquidityGross")
            );

            tickInfos.push(
                TickInfoSnapshot({
                    tick: tick,
                    liquidityNet: liquidityNet,
                    liquidityGross: liquidityGross
                })
            );
        }

        // Load bitmap snapshot
        string memory bitmapJson = vm.readFile(BITMAP_SNAPSHOT_PATH);
        string[] memory bitmapKeys = vm.parseJsonKeys(bitmapJson, "$");

        for (uint i = 0; i < bitmapKeys.length; i++) {
            string memory key = bitmapKeys[i];
            int16 wordPos = int16(vm.parseInt(key));
            string memory value = vm.parseJsonString(
                bitmapJson,
                string.concat("$.", key)
            );

            bitmapWords.push(
                BitmapWordSnapshot({wordPos: wordPos, value: value})
            );
        }

        // --- Calculate Storage Slots ---
        bytes32 localBaseSlot = StateLibrary._getPoolStateSlot(poolId); // Correct base slot using packed hash
        bytes32 tickBitmapBase = bytes32(uint256(localBaseSlot) + 5); // S+5
        bytes32 ticksBase = bytes32(uint256(localBaseSlot) + 4); // S+4
        bytes32 liquiditySlot = bytes32(uint256(localBaseSlot) + 3); // S+3

        // --- 3. Write bitmap words ---
        console.log("Storing bitmap words...");
        for (uint i = 0; i < bitmapWords.length; ++i) {
            int16 wordPos = bitmapWords[i].wordPos;
            // Parse the hex string value from JSON (remove 0x if present)
            uint256 bitmapValue = vm.parseUint(bitmapWords[i].value);
            bytes32 wordSlot = keccak256(
                abi.encode(int256(wordPos), tickBitmapBase)
            );
            vm.store(address(manager), wordSlot, bytes32(bitmapValue));
        }

        // --- 4. Write TickInfo structs ---
        console.log("Storing TickInfo...");
        for (uint i = 0; i < tickInfos.length; ++i) {
            int24 tick = tickInfos[i].tick;
            int128 liquidityNet = int128(
                vm.parseInt(tickInfos[i].liquidityNet)
            );
            int128 liquidityGross = int128(
                vm.parseInt(tickInfos[i].liquidityGross)
            );

            // Base slot for this TickInfo = keccak256(abi.encodePacked(int256(tick), ticksBase))
            bytes32 tickInfoBaseSlot = keccak256(
                abi.encode(int256(tick), ticksBase)
            );
            // bytes32 tickInfoSlot1 = bytes32(uint256(tickInfoBaseSlot) + 1);
            // bytes32 tickInfoSlot2 = bytes32(uint256(tickInfoBaseSlot) + 2);

            // Pack Net (upper 128) and Gross (lower 128) into the first slot
            uint256 packed = (uint256(int256(liquidityNet)) << 128) |
                uint256(uint128(liquidityGross));
            bytes32 slot0Value = bytes32(packed);
            vm.store(address(manager), tickInfoBaseSlot, slot0Value);
        }

        // --- 5. Write pool-level liquidity ---
        console.log("Storing active liquidity...");
        vm.store(address(manager), liquiditySlot, bytes32(uint256(INIT_LIQ)));

        // --- 6. Sanity check ---
        console.log("Performing sanity checks...");
        // Check Slot0 values set by initialize()
        (
            uint160 currentSqrtP,
            int24 currentTick,
            ,
            uint24 currentLpFee
        ) = manager.getSlot0(poolId);
        assertEq(
            currentSqrtP,
            INIT_SQRT_PRICE,
            "Initial SqrtPrice mismatch after setup"
        );
        // Allow for tiny tick difference due to calculation precision vs snapshot block
        assertTrue(
            abs(currentTick - TickMath.getTickAtSqrtPrice(INIT_SQRT_PRICE)) <=
                1,
            "Initial Tick mismatch after setup"
        );
        // For dynamic fee flag, initial LP fee in Slot0 should be 0
        assertEq(
            currentLpFee,
            0,
            "Initial LP Fee should be 0 for dynamic flag"
        );

        // Check a sample tick bitmap word stored via vm.store
        if (bitmapWords.length > 0) {
            int16 checkWordPos = bitmapWords[0].wordPos;
            uint256 checkBitmapValue = vm.parseUint(bitmapWords[0].value);
            bytes32 checkWordSlot = keccak256(
                abi.encode(int256(checkWordPos), tickBitmapBase)
            );
            bytes32 storedBitmapBytes = vm.load(
                address(manager),
                checkWordSlot
            );
            assertEq(
                uint256(storedBitmapBytes),
                checkBitmapValue,
                "Bitmap word mismatch after vm.store"
            );
        }

        // Check a sample TickInfo struct stored via vm.store
        if (tickInfos.length > 0) {
            int24 checkTick = tickInfos[0].tick;
            int128 checkNet = int128(vm.parseInt(tickInfos[0].liquidityNet));
            int128 checkGross = int128(
                vm.parseInt(tickInfos[0].liquidityGross)
            );
            bytes32 checkTickInfoBaseSlot = keccak256(
                abi.encode(int256(checkTick), ticksBase)
            );
            bytes32 storedTickInfoSlot0Bytes = vm.load(
                address(manager),
                checkTickInfoBaseSlot
            );
            // Re-pack expected value
            bytes32 expectedSlot0Value = bytes32(
                (uint256(int256(checkNet)) << 128) |
                    uint256(uint128(checkGross))
            );
            assertEq(
                storedTickInfoSlot0Bytes,
                expectedSlot0Value,
                "TickInfo slot 0 mismatch after vm.store"
            );
        }
    }

    /* ---------- the actual replay test ------------------------- */
    function test_replaySwaps() public {
        /* 1. read file */
        string memory json = vm.readFile("./swaps-v4.json");

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
            // amount0 is WETH (18 dec), amount1 is USDC (6 dec),
            int256 amount0 = _stringToFixed(s.amount0, 18);
            int256 amount1 = _stringToFixed(s.amount1, 6);

            bool zeroForOne; // True if swapping WETH for USDC (selling currency0)
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

            _recordMetrics(delta, preSqrtPrice, preTick, s);
        }

        // Get the data into an output format
        _writeCsv();
    }

    /* ---------- helpers ---------------------------------------- */
    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

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
        int24 preTick,
        RawSwap memory recordedSwap
    ) internal {
        // Get current state (post-swap)
        (uint160 postSqrtPrice, int24 postTick, , uint24 postFee) = manager
            .getSlot0(poolId);

        // Get the expected fee (what it should have been based on the delta ticks)
        uint24 expectedFee = feeFromDelta(int256(postTick) - int256(preTick));

        // Carry (fee error between expected and actual)
        int24 carry = hook.getPred(poolId).carry;

        int24 expectedTick = int24(_stringToFixed(recordedSwap.tick, 0));

        // Calculate expected and actual prices in USDC
        // Expected price uses the sqrtPriceX96 reported in the JSON for *after* that swap
        uint256 sqrtPriceUint = vm.parseUint(recordedSwap.sqrtPriceX96); // Safer parsing
        uint256 expectedPrice = _calculateUsdcPrice(uint160(sqrtPriceUint));

        // Actual price uses the sqrtPriceX96 read from the local pool *after* executing the swap
        uint256 actualPrice = _calculateUsdcPrice(postSqrtPrice);

        swaps.push(
            SwapMetrics({
                amount0: delta.amount0(),
                amount1: delta.amount1(),
                sqrtPriceBefore: preSqrtPrice,
                sqrtPriceAfter: postSqrtPrice,
                tickBefore: preTick,
                tickAfter: postTick,
                expectedTickAfter: expectedTick,
                expectedFee: expectedFee,
                actualFee: postFee,
                carry: carry,
                expectedUsdcPrice: expectedPrice,
                actualUsdcPrice: actualPrice
            })
        );
    }

    function _calculateUsdcPrice(
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 price) {
        // The formula is (sqrtPriceX96/2^96)^2 * 10^12
        uint256 scaleFactor = 1e12;

        // First convert sqrtPriceX96 to a decimal value by dividing by 2^96
        uint256 sqrtPrice = FullMath.mulDiv(
            sqrtPriceX96,
            scaleFactor,
            FixedPoint96.Q96
        );

        // Now square it to get the final price (with 10^12 scaling already applied)
        price = FullMath.mulDiv(sqrtPrice, sqrtPrice, scaleFactor);
    }

    function _writeCsv() internal {
        string memory path = "./storage/metrics.csv";
        vm.writeFile(
            path,
            "idx,expected_fee,actual_fee,carry,expected_price,actual_price,expected_tickAfter,actual_tickAfter\n"
        );
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
                    vm.toString(swaps[i].carry),
                    ",",
                    vm.toString(swaps[i].expectedUsdcPrice),
                    ",",
                    vm.toString(swaps[i].actualUsdcPrice),
                    ",",
                    vm.toString(swaps[i].expectedTickAfter),
                    ",",
                    vm.toString(swaps[i].tickAfter)
                )
            );
        }
        emit log_string(
            string.concat("CSV written: ", path, "  (ready for Python)")
        );
    }
}
