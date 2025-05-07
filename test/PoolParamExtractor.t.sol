// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";


interface IUniswapV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16,
        uint16,
        uint16,
        uint8,
        bool
    );
}

contract PoolParamExtractor is Test {
    using stdJson for string;

    function testExtractAndWritePoolConfig() public {
        address POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640; // USDC/WETH 0.05% pool

        // IUniswapV3Pool target = IUniswapV3Pool(pool);
        uint numBlocks = 100;
        uint256 startBlock = 12376891;
        
        string memory key = vm.envString("INFURA_KEY");
        string memory RPC = string.concat("https://mainnet.infura.io/v3/", key);

        string memory all = "{}";

        for (uint256 i = 0; i < numBlocks; i++) {
            uint256 blockNum = startBlock + i;
            emit log_named_uint("Processing block", blockNum); // <--- real-time log

            vm.createSelectFork(RPC, blockNum);

            IUniswapV3Pool target = IUniswapV3Pool(POOL);

            address token0 = target.token0();
            address token1 = target.token1();
            uint24 fee = target.fee();
            int24 tickSpacing = target.tickSpacing();
            uint128 liquidity = target.liquidity();
            ( , int24 tick,,,,,) = target.slot0();

            uint160 computedSqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

            string memory obj = "config";
            vm.serializeAddress(obj, "token0", token0);
            vm.serializeAddress(obj, "token1", token1);
            vm.serializeUint(obj, "fee", fee);
            vm.serializeInt(obj, "tickSpacing", tickSpacing);
            vm.serializeInt(obj, "tick", tick);
            vm.serializeUint(obj, "sqrtPriceX96", computedSqrtPriceX96);
            vm.serializeUint(obj, "liquidity", liquidity);
            string memory configJson = vm.serializeString(obj, "poolAddress", vm.toString(POOL));

            // Store under .<blockNum>
            all = vm.serializeString("all", vm.toString(blockNum), configJson);
        }

        vm.writeJson(all, "./storage/pool_config_by_block.json");

        emit log_string("Pool config written to ./storage/pool_config.json");
    }
}
