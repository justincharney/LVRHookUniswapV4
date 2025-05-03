const { ethers } = require("ethers");

const providerUrl =
  "https://mainnet.infura.io/v3/87d1cad6d0684d9291d3b40a8f7cbab6";
const provider = new ethers.JsonRpcProvider(providerUrl);

const poolAddress = "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640";
const token0Address = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"; // USDC
const token1Address = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"; // WETH
const blockNumber = 12376890; // One block before the oldest swap we are going to replay

const token0decimals = 6;
const token1decimals = 18;

const erc20Abi = ["function balanceOf(address account) view returns (uint256)"];

const v3PoolAbi = [
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
  "function liquidity() view returns (uint128)",
];

async function getHistoricalReserves(poolAddr, t0Addr, t1Addr, blockNum) {
  const token0Contract = new ethers.Contract(t0Addr, erc20Abi, provider);
  const token1Contract = new ethers.Contract(t1Addr, erc20Abi, provider);

  try {
    const balance0 = await token0Contract.balanceOf(poolAddr, {
      blockTag: blockNum,
    });
    const balance1 = await token1Contract.balanceOf(poolAddr, {
      blockTag: blockNum,
    });

    console.log(`Reserves at block ${blockNum}:`);
    console.log(
      ` Token0 (${t0Addr}): ${ethers.formatUnits(balance0, token0decimals)}`,
    ); // Replace decimals
    console.log(
      ` Token1 (${t1Addr}): ${ethers.formatUnits(balance1, token1decimals)}`,
    ); // Replace decimals

    return { balance0, balance1 };
  } catch (error) {
    console.error("Error fetching historical reserves:", error);
    // Common error: Node is not an archive node or block is too old
    if (error.message.includes("missing trie node")) {
      console.error(
        "This likely requires an Archive Node for the requested block.",
      );
    }
    return null;
  }
}

async function getHistoricalPoolState(poolAddr, blockNum) {
  const poolContract = new ethers.Contract(poolAddr, v3PoolAbi, provider);

  console.log(`\n--- Fetching Pool State at block ${blockNum} ---`);
  try {
    const slot0Data = await poolContract.slot0({ blockTag: blockNum });
    const currentLiquidity = await poolContract.liquidity({
      blockTag: blockNum,
    });

    console.log(` Pool Address: ${poolAddr}`);
    console.log(` Slot0:`);
    console.log(`  sqrtPriceX96: ${slot0Data.sqrtPriceX96.toString()}`);
    console.log(`  tick: ${slot0Data.tick.toString()}`);
    // Add other slot0 fields if needed
    console.log(` Liquidity: ${currentLiquidity.toString()}`);

    // You can calculate the price from sqrtPriceX96 if needed:
    // price = (sqrtPriceX96 / 2**96)**2
    const priceRatio = (Number(slot0Data.sqrtPriceX96) / 2 ** 96) ** 2;
    // Price is typically quoted as token1/token0. Adjust for decimals.
    const priceToken1ForToken0 =
      (priceRatio * 10 ** token0decimals) / 10 ** token1decimals;
    const priceToken0ForToken1 = 1 / priceToken1ForToken0;

    console.log(
      ` Calculated Price (Token1 per Token0): ~${priceToken1ForToken0.toFixed(token0decimals)} WETH/USDC`,
    );
    console.log(
      ` Calculated Price (Token0 per Token1): ~${priceToken0ForToken1.toFixed(2)} USDC/WETH`,
    );

    return { slot0: slot0Data, liquidity: currentLiquidity };
  } catch (error) {
    console.error("Error fetching historical pool state:", error.message);
    if (
      error.message.includes("missing trie node") ||
      error.message.includes("header not found") ||
      error.message.includes("doesn't exist")
    ) {
      console.error(
        `Error: The RPC node might not have data for block ${blockNum}. This often requires an Archive Node.`,
      );
    }
    return null;
  }
}

// getHistoricalReserves(poolAddress, token0Address, token1Address, blockNumber);

getHistoricalPoolState(poolAddress, blockNumber);
