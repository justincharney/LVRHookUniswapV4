// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol"; // <-- this is the missing piece
import {stdJson} from "forge-std/StdJson.sol";
import {BaseSwapReplayTest} from "./replay/BaseSwapReplayTest.sol";


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

contract ReplaySwapsFromBlock is Test, Fixtures, BaseSwapReplayTest {
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using stdJson for string;
    using StateLibrary for IPoolManager;

    VarianceFeeHook hook;
    PoolKey internal pkey;
    PoolId internal poolId;

    struct PoolConfig {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    function _loadPoolConfig(string memory path, string memory blockKey)
        internal
        view
        returns (PoolConfig memory config)
    {
        string memory raw = vm.readFile(path);
        string memory prefix = string.concat(".", blockKey);
        config.token0 = raw.readAddress(string.concat(prefix, ".token0"));
        config.token1 = raw.readAddress(string.concat(prefix, ".token1"));
        config.fee = uint24(raw.readUint(string.concat(prefix, ".fee")));
        config.tickSpacing = int24(raw.readInt(string.concat(prefix, ".tickSpacing")));
        config.sqrtPriceX96 = uint160(raw.readUint(string.concat(prefix, ".sqrtPriceX96")));
        config.liquidity = uint128(raw.readUint(string.concat(prefix, ".liquidity")));
    }

    function setUp() public {
        PoolConfig memory cfg = _loadPoolConfig("./storage/pool_config_by_block.json", "12376891");
        
        // console.log("Loaded config:");
        // console.log("token0: %s", cfg.token0);
        // console.log("token1: %s", cfg.token1);
        // console.log("tickSpacing: %d", cfg.tickSpacing);
        // console.log("sqrtPriceX96: %s", cfg.sqrtPriceX96);
        // console.log("liquidity: %s", cfg.liquidity);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("VarianceFeeHook.sol:VarianceFeeHook", abi.encode(manager), hookAddr);
        hook = VarianceFeeHook(hookAddr);

        pkey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(hook)
        });
        

        poolId = pkey.toId();
        manager.initialize(pkey, cfg.sqrtPriceX96);

        int24 low = TickMath.minUsableTick(pkey.tickSpacing);
        int24 high = TickMath.maxUsableTick(pkey.tickSpacing);
        console.log("low: %d", low);
        console.log("high: %d", high);
        // uint128 liq = cfg.liquidity;
        uint128 liq = 10000e18;

        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            cfg.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(low),
            TickMath.getSqrtPriceAtTick(high),
            liq
        );
        console.log("a0: %s", a0);
        console.log("a1: %s", a1);

        posm.mint(pkey, low, high, liq, a0 + 1, a1 + 1, address(this), block.timestamp, "");
    }

    function test_replaySwaps_withPoolInfo() public {
        string memory json = vm.readFile("./swaps.json");
        bytes memory arr = json.parseRaw(".data.pool.swaps");
        RawSwap[] memory rswaps = abi.decode(arr, (RawSwap[]));

        for (uint i = 0; i < rswaps.length; ++i) {
            RawSwap memory s = rswaps[i];
            if (i == 1) break;

            // console.log("--- Swap %s ---", i);
            // console.log("RawSwap.amount0: %s", s.amount0);
            // console.log("RawSwap.amount1: %s", s.amount1);
            // console.log("sqrtPriceX96 in JSON: %s", s.sqrtPriceX96);

            (uint160 preSqrtPrice, int24 preTick, , ) = manager.getSlot0(poolId);
            (int256 amount0, int256 amount1) = _castAmounts(s.amount0, s.amount1);

            bool zeroForOne = amount0 < 0;
            int256 amountSpecified = zeroForOne ? amount0 : amount1;
            console.log("--- Swap From Block %s ---", i);
            console.log("PreSwap sqrtPrice: %s", preSqrtPrice);
            console.log("PreSwap tick: %d", preTick);
            console.log("amount0 (cast): %s", amount0);
            console.log("amount1 (cast): %s", amount1);
            console.log("zeroForOne: %s", zeroForOne ? "true" : "false");
            console.log("amountSpecified: %s", amountSpecified);

            BalanceDelta delta = swap(pkey, zeroForOne, amountSpecified, ZERO_BYTES);
            (uint160 postSqrtPrice, int24 postTick, , uint24 postFee) = manager.getSlot0(poolId);
            int24 carry = hook.getPred(poolId).carry;

            _recordMetrics(
                delta,
                preSqrtPrice,
                preTick,
                manager,
                poolId,
                carry,
                postFee
            );
        }

        _writeCsv("storage/metrics_real.csv");
    }
}
