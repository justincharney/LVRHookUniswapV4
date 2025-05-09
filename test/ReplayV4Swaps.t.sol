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
        weth  = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc  = new MockERC20("USD Coin",      "USDC",  6);

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
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144));
        deployCodeTo("VarianceFeeHook.sol:VarianceFeeHook", abi.encode(manager), hookAddr);
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
        bytes32 liquiditySlot = bytes32(uint256(StateLibrary._getPoolStateSlot(poolId)) + 3);
        vm.store(address(manager), liquiditySlot, bytes32(uint256(INIT_LIQ)));
    }

    /* ---------- the actual replay test ------------------------- */
    function test_replaySwaps() public {
        string memory json = vm.readFile("./swaps-v4.json");
        bytes memory arr = json.parseRaw(".data.pool.swaps");
        RawSwap[] memory rswaps = abi.decode(arr, (RawSwap[]));

        for (uint i = 1; i < 25; ++i) {
            RawSwap memory s = rswaps[i];
            uint256 blk = uint256(vm.parseInt(s.transaction.blockNumber));
            _applySnapshot(blk);  // ensures liquidity is right for this block

            // --- Restore tick + bitmap state for this block ---
            uint blockNum = uint(vm.parseInt(s.transaction.blockNumber));
            string memory tickJson = vm.readFile("./tick_snapshot.json");
            string memory bitmapJson = vm.readFile("./bitmap_snapshot.json");

            string[] memory tickKeys = vm.parseJsonKeys(tickJson, string.concat("$.", vm.toString(blockNum)));
            delete tickInfos;
            for (uint j = 0; j < tickKeys.length; j++) {
                string memory key = tickKeys[j];
                string memory pathBase = string.concat("$.", vm.toString(blockNum), ".", key);

                string memory net = vm.parseJsonString(tickJson, string.concat(pathBase, ".liquidityNet"));
                string memory gross = vm.parseJsonString(tickJson, string.concat(pathBase, ".liquidityGross"));

                require(bytes(net).length > 0, string.concat("Missing liquidityNet at block ", vm.toString(blockNum), " tick ", key));
                require(bytes(gross).length > 0, string.concat("Missing liquidityGross at block ", vm.toString(blockNum), " tick ", key));

                int24 parsedTick = int24(vm.parseInt(key));  // ✅ Now we parse only after checking

                tickInfos.push(TickInfoSnapshot({
                    tick: parsedTick,
                    liquidityNet: net,
                    liquidityGross: gross
                }));
            }


            string[] memory bitmapKeys = vm.parseJsonKeys(bitmapJson, string.concat("$.", vm.toString(blockNum)));
            delete bitmapWords;
            for (uint j = 0; j < bitmapKeys.length; j++) {
                string memory key = bitmapKeys[j];
                string memory path = string.concat("$.", vm.toString(blockNum), ".", key);
                string memory val = vm.parseJsonString(bitmapJson, path);

                require(bytes(val).length > 0, string.concat("Missing bitmap value at block ", vm.toString(blockNum), " pos ", key));

                int16 parsedWord = int16(vm.parseInt(key));  // ✅ Safe now

                bitmapWords.push(BitmapWordSnapshot({
                    wordPos: parsedWord,
                    value: val
                }));
            }



            // --- Write tick and bitmap state to storage ---
            bytes32 baseSlot = StateLibrary._getPoolStateSlot(poolId);
            bytes32 tickBitmapBase = bytes32(uint256(baseSlot) + 5);
            bytes32 ticksBase = bytes32(uint256(baseSlot) + 4);

            for (uint j = 0; j < bitmapWords.length; j++) {
                int16 wordPos = bitmapWords[j].wordPos;
                uint256 val = vm.parseUint(bitmapWords[j].value);
                bytes32 wordSlot = keccak256(abi.encode(int256(wordPos), uint256(tickBitmapBase)));
                vm.store(address(manager), wordSlot, bytes32(val));
            }

            for (uint j = 0; j < tickInfos.length; j++) {
                int24 tick = tickInfos[j].tick;
                int256 net = int256(vm.parseInt(tickInfos[j].liquidityNet));
                uint128 gross = uint128(vm.parseUint(tickInfos[j].liquidityGross));
                bytes32 tickSlot = keccak256(abi.encode(int256(tick), uint256(ticksBase)));
                bytes32 slotVal = bytes32((uint256(net) << 128) | uint256(gross));
                vm.store(address(manager), tickSlot, slotVal);
            }

            // --- Optional: Validate state restore for this block ---
            if (bitmapWords.length > 0) {
                int16 checkWordPos = bitmapWords[0].wordPos;
                uint256 checkBitmapValue = vm.parseUint(bitmapWords[0].value);
                bytes32 checkWordSlot = keccak256(abi.encode(int256(checkWordPos), uint256(tickBitmapBase)));
                bytes32 storedBitmap = vm.load(address(manager), checkWordSlot);
                assertEq(uint256(storedBitmap), checkBitmapValue, "Mismatch in bitmap restore");
            }

            if (tickInfos.length > 0) {
                int24 checkTick = tickInfos[0].tick;
                int256 checkNet = int256(vm.parseInt(tickInfos[0].liquidityNet));
                uint128 checkGross = uint128(vm.parseUint(tickInfos[0].liquidityGross));
                bytes32 checkTickSlot = keccak256(abi.encode(int256(checkTick), uint256(ticksBase)));
                bytes32 storedTick = vm.load(address(manager), checkTickSlot);
                bytes32 expectedTick = bytes32((uint256(checkNet) << 128) | uint256(checkGross));
                assertEq(storedTick, expectedTick, "Mismatch in tick restore");
            }


            // --- Save pre-swap state ---
            (uint160 preSqrtPrice, int24 preTick, , ) = manager.getSlot0(poolId);
            bool wethIs0 = Currency.unwrap(currency0) == address(weth);

            int256 jsonWeth = _stringToFixed(s.amount0, 18);
            int256 jsonUsdc = _stringToFixed(s.amount1, 6);
            int256 amount0_pool_delta_local = wethIs0 ? jsonWeth : jsonUsdc;
            int256 amount1_pool_delta_local = wethIs0 ? jsonUsdc : jsonWeth;

            bool zeroForOne_final;
            int256 amountToSpecifyForExactInput;
            if (amount1_pool_delta_local > 0) {
                require(amount0_pool_delta_local < 0, "Data Error: currency0 should have left.");
                zeroForOne_final = false;
                amountToSpecifyForExactInput = -amount1_pool_delta_local;
            } else if (amount0_pool_delta_local > 0) {
                require(amount1_pool_delta_local < 0, "Data Error: currency1 should have left.");
                zeroForOne_final = true;
                amountToSpecifyForExactInput = -amount0_pool_delta_local;
            } else {
                revert("Invalid swap data in JSON: No input detected.");
            }

            console.log("ReplayV4Swaps: Swap #%s", vm.toString(i));
            console.log("ReplayV4Swaps: zeroForOne_final = %s", vm.toString(zeroForOne_final));
            console.log("ReplayV4Swaps: amountToSpecifyForExactInput = %s", vm.toString(amountToSpecifyForExactInput));

            BalanceDelta delta = swap(
                pkey,
                zeroForOne_final,
                amountToSpecifyForExactInput,
                ZERO_BYTES
            );

            _recordMetrics(delta, preSqrtPrice, preTick, s);
        }

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
                tickFile   = vm.readFile(TICK_SNAP);
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
                int24  tick = int24(vm.parseInt(tickKeys[i]));

                // Construct the full path from the root of tickFile
                string memory tickSpecificPath = string.concat(blockPath, ".", tickKeys[i]);
                string memory lnPath = string.concat(tickSpecificPath, ".liquidityNet");
                string memory lgPath = string.concat(tickSpecificPath, ".liquidityGross");

                string memory ln  = vm.parseJsonString(tickFile, lnPath);
                string memory lg  = vm.parseJsonString(tickFile, lgPath);

                bytes32 slot = keccak256(abi.encode(int256(tick), uint256(ticksBase)));
                vm.store(
                    address(manager),
                    slot,
                    bytes32(
                        (uint256(int256(vm.parseInt(ln))) << 128) |
                        uint256(vm.parseUint(lg))
                    )
                );
            }

            // 3b. bitmap words
            string[] memory bmKeys = vm.parseJsonKeys(bitmapFile, blockPath);
            bytes32 bitmapBase = bytes32(
                uint256(StateLibrary._getPoolStateSlot(poolId)) + 5
            );

            for (uint i; i < bmKeys.length; ++i) {
                int16 wordPos = int16(vm.parseInt(bmKeys[i]));
                string memory wordSpecificPath = string.concat(blockPath, ".", bmKeys[i]);
                string memory hexValueString = vm.parseJsonString(bitmapFile, wordSpecificPath);
                uint256 value = vm.parseUint(hexValueString);
                bytes32 slot = keccak256(abi.encode(int256(wordPos), uint256(bitmapBase)));
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
