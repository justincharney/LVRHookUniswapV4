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
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";

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
        Transaction transaction;
    }

    struct Transaction {
        string blockNumber;
        string timestamp;
    }

    /* ---------- Metrics from the swaps -------------- */
    struct SwapMetrics {
        uint256 blk;
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

    MockERC20 public weth;
    uint256 private currentBlockNumber = 0;

    string private constant TICK_SNAP = "./tick_snapshot.json";
    string private constant BM_SNAP = "./bitmap_snapshot.json";

    string private tickFile;
    string private bitmapFile;

    // JSON file paths
    string constant TICK_SNAPSHOT_PATH = "./tick_snapshot.json";
    string constant BITMAP_SNAPSHOT_PATH = "./bitmap_snapshot.json";

    TickInfoSnapshot[] public tickInfos;
    BitmapWordSnapshot[] public bitmapWords;

    /* ---------- set-up ----------------------------------------- */
    function setUp() public {
        // --- 1. Deploy manager, hook, pool ---
        deployFreshManagerAndRouters();
        // --- deploy tokens with the right decimals --------------------
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        // mint plenty to this test contract & pool manager
        weth.mint(address(this), 100_000 ether);
        usdc.mint(address(this), 500_000_000 * 1e6);
        weth.mint(address(manager), 100_000 ether);
        usdc.mint(address(manager), 500_000_000 * 1e6);

        // give all the PoolManager test routers unlimited allowance
        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];
        for (uint i; i < toApprove.length; ++i) {
            weth.approve(toApprove[i], type(uint256).max);
            usdc.approve(toApprove[i], type(uint256).max);
        }

        // wrap into Currency and sort by address (the helper does the same)
        (currency0, currency1) = SortTokens.sort(weth, usdc);

        // Deploy Hook
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

        // Pool Key setup
        pkey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });
        poolId = pkey.toId();

        // Initialize Pool - sets initial Slot0
        manager.initialize(pkey, INIT_SQRT_PRICE);

        // Write pool-level liquidity
        console.log("Storing active liquidity...");
        bytes32 liquiditySlot = bytes32(
            uint256(StateLibrary._getPoolStateSlot(poolId)) + 3
        );
        vm.store(address(manager), liquiditySlot, bytes32(uint256(INIT_LIQ)));
    }

    /* ---------- the actual replay test ------------------------- */
    function test_replaySwaps() public {
        /* 1. read file */
        string memory json = vm.readFile("./swaps-v4.json");

        bytes memory arr = json.parseRaw(".data.pool.swaps"); // returns the ABI-encoded array
        RawSwap[] memory rswaps = abi.decode(arr, (RawSwap[]));

        /* 2. loop over them, staring from the second swap */
        for (uint i = 1; i < rswaps.length; ++i) {
            RawSwap memory s = rswaps[i];
            uint256 blk = uint256(vm.parseInt(s.transaction.blockNumber));
            _applySnapshot(blk); // ensures liquidity is right for this block

            // Save pre-swap state
            (uint160 preSqrtPrice, int24 preTick, , ) = manager.getSlot0(
                poolId
            );

            bool wethIs0 = Currency.unwrap(currency0) == address(weth);

            // 1. Parse the JSON strictly in pool‑on‑chain order
            int256 jsonWeth = _stringToFixed(s.amount0, 18);
            int256 jsonUsdc = _stringToFixed(s.amount1, 6);

            // 2. Convert to local token‑order units
            // amount0 represents the change in the pool's currency0 balance
            // amount1 represents the change in the pool's currency1 balance
            int256 amount0_pool_delta_local = wethIs0 ? jsonWeth : jsonUsdc;
            int256 amount1_pool_delta_local = wethIs0 ? jsonUsdc : jsonWeth;

            // 3. Work out direction & amountSpecified FOR AN EXACT INPUT SWAP
            bool zeroForOne_final;
            int256 amountToSpecifyForExactInput;

            // If a pool_delta is POSITIVE, that token ENTERED the pool (it was the swapper's INPUT).
            // If a pool_delta is NEGATIVE, that token LEFT the pool (it was the swapper's OUTPUT).

            if (amount1_pool_delta_local > 0) {
                // Swapper input currency1. Pool received currency1.
                // currency0 must have been output (amount0_pool_delta_local < 0).
                require(
                    amount0_pool_delta_local < 0,
                    "Data Error: If currency1 entered pool, currency0 should have left."
                );
                zeroForOne_final = false; // Selling currency1 for currency0
                amountToSpecifyForExactInput = -amount1_pool_delta_local; // NEGATIVE of the input currency1 amount
            } else if (amount0_pool_delta_local > 0) {
                // Swapper input currency0. Pool received currency0.
                // currency1 must have been output (amount1_pool_delta_local < 0).
                require(
                    amount1_pool_delta_local < 0,
                    "Data Error: If currency0 entered pool, currency1 should have left."
                );
                zeroForOne_final = true; // Selling currency0 for currency1
                amountToSpecifyForExactInput = -amount0_pool_delta_local; // NEGATIVE of the input currency0 amount
            } else {
                // This case implies both deltas are non-positive, or one is zero and the other non-positive.
                // For a typical swap from your JSON (one in, one out), this shouldn't be hit.
                revert(
                    "Invalid swap data in JSON: Pool deltas do not indicate a clear input token for the swapper."
                );
            }

            console.log("ReplayV4Swaps: Swap #%s", vm.toString(i));
            console.log(
                "ReplayV4Swaps: zeroForOne_final = %s",
                vm.toString(zeroForOne_final)
            );
            console.log(
                "ReplayV4Swaps: amountToSpecifyForExactInput = %s",
                vm.toString(amountToSpecifyForExactInput)
            );
            // Add more logs from previous suggestion if needed

            // run swap through the standard helper from Fixtures
            BalanceDelta delta = swap(
                pkey,
                zeroForOne_final,
                amountToSpecifyForExactInput, // This will now be NEGATIVE
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

    function _applySnapshot(uint256 blockNumber) internal {
        if (blockNumber == currentBlockNumber) return;
        currentBlockNumber = blockNumber;

        // Load the files once
        if (bytes(tickFile).length == 0) {
            tickFile = vm.readFile(TICK_SNAP);
            bitmapFile = vm.readFile(BM_SNAP);
        }

        // Keys in the top‑level objects are the block numbers as strings
        string memory blockPath = string.concat("$.", vm.toString(blockNumber));

        // 3a. ticks
        // Get keys of the object at tickFile.blockPath (e.g., keys of tickFile."$.21763873")
        string[] memory tickKeys = vm.parseJsonKeys(tickFile, blockPath);
        bytes32 ticksBase = bytes32(
            uint256(StateLibrary._getPoolStateSlot(poolId)) + 4
        );

        for (uint i; i < tickKeys.length; ++i) {
            // skip metadata entry "__L"
            bytes memory key = bytes(tickKeys[i]);
            if (key.length > 0 && key[0] == "_") {
                continue;
            }
            int24 tick = int24(vm.parseInt(tickKeys[i]));
            // Construct the full path from the root of tickFile
            string memory tickSpecificPath = string.concat(
                blockPath,
                ".",
                tickKeys[i]
            );
            string memory lnPath = string.concat(
                tickSpecificPath,
                ".liquidityNet"
            );
            string memory lgPath = string.concat(
                tickSpecificPath,
                ".liquidityGross"
            );

            string memory ln = vm.parseJsonString(tickFile, lnPath);
            string memory lg = vm.parseJsonString(tickFile, lgPath);

            bytes32 slot = keccak256(
                abi.encode(int256(tick), uint256(ticksBase))
            );
            vm.store(
                address(manager),
                slot,
                bytes32(
                    (uint256(int256(vm.parseInt(ln))) << 128) |
                        uint256(vm.parseUint(lg))
                )
            );
        }

        // 3b. apply the active-liquidity snapshot (“__L”)
        // {
        //     // parse the JSON string at blockPath.__L
        //     string memory Lpath = string.concat(blockPath, ".__L");
        //     uint256 L = vm.parseUint(vm.parseJsonString(tickFile, Lpath));
        //     // compute the pool-state liquidity slot = S + 3
        //     bytes32 liquiditySlot = bytes32(
        //         uint256(StateLibrary._getPoolStateSlot(poolId)) + 3
        //     );
        //     vm.store(address(manager), liquiditySlot, bytes32(L));
        // }

        // 3c. bitmap words
        string[] memory bmKeys = vm.parseJsonKeys(bitmapFile, blockPath);
        bytes32 bitmapBase = bytes32(
            uint256(StateLibrary._getPoolStateSlot(poolId)) + 5
        );

        for (uint i; i < bmKeys.length; ++i) {
            int16 wordPos = int16(vm.parseInt(bmKeys[i]));
            string memory wordSpecificPath = string.concat(
                blockPath,
                ".",
                bmKeys[i]
            );
            string memory hexValueString = vm.parseJsonString(
                bitmapFile,
                wordSpecificPath
            );
            uint256 value = vm.parseUint(hexValueString);
            bytes32 slot = keccak256(
                abi.encode(int256(wordPos), uint256(bitmapBase))
            );
            vm.store(address(manager), slot, bytes32(value));
        }
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
        // Get the block
        uint256 blk = uint256(
            vm.parseInt(recordedSwap.transaction.blockNumber)
        );

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
                blk: blk,
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
            "idx,blk,expected_fee,actual_fee,carry,expected_price,actual_price,expected_tickAfter,actual_tickAfter\n"
        );
        for (uint i; i < swaps.length; ++i) {
            vm.writeLine(
                path,
                string.concat(
                    vm.toString(i),
                    ",",
                    vm.toString(swaps[i].blk),
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
