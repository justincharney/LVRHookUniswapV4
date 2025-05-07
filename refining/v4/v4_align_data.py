import json
import pandas as pd

'''
Matches Ethereum Uniswap v3 swap events from swaps_with_timestamp.json
with Coinbase ETH-USDC CEX price data from eth_usdc_coinbase_prices_1s.csv.

Outputs swap data with corresponding CEX price.
'''

# Loads CEX data and sets timestamp as index
cex_df = pd.read_csv("refining/v4_eth_usdc_coinbase_prices_1s.csv")
cex_df.set_index("cex_timestamp", inplace=True)

# Loads uniswap v3 swap data
with open("./v4_swaps_with_timestamp.json") as f:
    swap_data = json.load(f)

# Extracts relevant info
pool_id = swap_data["data"]["pool"]["id"]
swaps = swap_data["data"]["pool"]["swaps"]

# For each swap, get timestamp
filtered_swaps = []
for swap in swaps:
    timestamp = swap.get("timestamp")
    if timestamp is None and "transaction" in swap:
        timestamp = swap["transaction"].get("timestamp")

    if timestamp is None:
        print(f"[Warning] No timestamp found in swap: {swap}")
        continue

    timestamp = int(timestamp)


    # Ensure time is in CEX info
    try:
        cex_price = cex_df.loc[timestamp, "cex_price"]
    except KeyError:
        print(f"[Warning] No CEX price for timestamp {timestamp}, skipping...")
        continue

    # Copy original swap and add CEX price
    enriched_swap = swap.copy()
    enriched_swap["cex_price"] = f"{round(cex_price, 6)}"
    enriched_swap["timestamp"] = str(timestamp)

    # Get token amounts
    try:
        amt0 = float(swap["amount0"])
        amt1 = float(swap["amount1"])
    except ValueError:
        print(f"[Warning] Invalid amounts at timestamp {timestamp}, skipping...")
        continue

    # Add amm_price
    # enriched_swap["amm_price"] = f"{round(abs(amt0/amt1), 6)}"

    # Filter for token type
    if amt0 > 0:
        enriched_swap["token_in"] = "token0"
    elif amt1 > 0:
        enriched_swap["token_in"] = "token1"
    else:
        enriched_swap["token_in"] = "unknown"

    filtered_swaps.append(enriched_swap)

# Maintain structure consistency
output = {
    "data": {
        "pool": {
            "id": pool_id,
            "swaps": filtered_swaps
        }
    }
}

# Write to output file
with open("./v4_swaps_with_cex.json", "w") as f:
    json.dump(output, f, indent=2)

print(f"Wrote {len(filtered_swaps)} swaps to v4_swaps_with_cex.json")
