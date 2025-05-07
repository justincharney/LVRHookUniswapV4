// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

abstract contract BaseSwapReplayTest is Test {
    using stdJson for string;
    using StateLibrary for IPoolManager;

    struct RawSwap {
        string amount0;
        string amount1;
        uint160 sqrtPriceX96;
        uint256 blockNumber;
    }

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
    uint24 internal constant BASE_FEE = 5000;

    function _toSignedFixed(string memory s, uint8 decimals) internal pure returns (int256) {
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
                fracLen = 1;
            } else {
                uint8 d = uint8(c) - 48;
                if (fracLen == 0) {
                    intPart = intPart * 10 + d;
                } else if (fracLen <= decimals) {
                    fracPart = fracPart * 10 + d;
                    ++fracLen;
                }
            }
        }

        while (fracLen++ < (decimals + 1)) fracPart *= 10;

        int256 scaled = int256(intPart * 10 ** decimals + fracPart);
        return neg ? -scaled : scaled;
    }

    // Adjust decimals for the real tokens
    uint8 constant DECIMALS_TOKEN0 = 6;  // USDC
    uint8 constant DECIMALS_TOKEN1 = 18; // WETH

    function _castAmounts(
        string memory a0,
        string memory a1
    ) internal pure returns (int256 amt0, int256 amt1) {
        amt0 = _toSignedFixed(a0, DECIMALS_TOKEN0);
        amt1 = _toSignedFixed(a1, DECIMALS_TOKEN1);
    }

    function feeFromDelta(int256 dtick) internal pure returns (uint24) {
        uint256 abs2 = uint256(dtick * dtick);
        uint256 fee = BASE_FEE + (abs2 * 125 + 100_000 - 1) / 100_000;
        if (fee > LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE;
        return uint24(fee);
    }

    function _recordMetrics(
        BalanceDelta delta,
        uint160 preSqrtPrice,
        int24 preTick,
        IPoolManager manager,
        PoolId poolId,
        int24 carry,
        uint24 postFee
    ) internal {
        (uint160 postSqrtPrice, int24 postTick,,) = manager.getSlot0(poolId);
        uint24 expectedFee = feeFromDelta(int256(postTick) - int256(preTick));

        swaps.push(SwapMetrics({
            amount0: delta.amount0(),
            amount1: delta.amount1(),
            sqrtPriceBefore: preSqrtPrice,
            sqrtPriceAfter: postSqrtPrice,
            tickBefore: preTick,
            tickAfter: postTick,
            expectedFee: expectedFee,
            actualFee: postFee,
            carry: carry
        }));
    }

    function _writeCsv(string memory path) internal {
        vm.writeFile(path, "idx,expected_fee,actual_fee,carry\n");
        for (uint i; i < swaps.length; ++i) {
            vm.writeLine(path, string.concat(
                vm.toString(i), ",",
                vm.toString(swaps[i].expectedFee), ",",
                vm.toString(swaps[i].actualFee), ",",
                vm.toString(swaps[i].carry)
            ));
        }
        emit log_string(string.concat("CSV written: ", path));
    }
}
