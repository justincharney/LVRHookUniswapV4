import json
import pandas as pd

'''

'''

# Loads CEX data and sets timestamp as index
cex_df = pd.read_csv("eth_usdc_coinbase_prices_1s.csv")
cex_df.set_index("cex_timestamp", inplace=True)

# Loads uniswap v3 swap data
with open("swaps_with_timestamp.json") as f:
    swap_data = json.load(f)

# Extracts relevant info
pool_id = swap_data["data"]["pool"]["id"]
swaps = swap_data["data"]["pool"]["swaps"]

# For each swap, get timestamp
filtered_swaps = []
for swap in swaps:
    timestamp = int(swap["timestamp"])

    # Ensure time is in CEX info
    try:
        cex_price = cex_df.loc[timestamp, "cex_price"]
    except KeyError:
        print(f"[Warning] No CEX price for timestamp {timestamp}, skipping...")
        continue

    # Copy original swap and add CEX price
    enriched_swap = swap.copy()
    enriched_swap["cex_price"] = f"{round(cex_price, 3)}"
    enriched_swap["timestamp"] = str(timestamp)
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
with open("../swaps_with_cex.json", "w") as f:
    json.dump(output, f, indent=2)

print(f"Wrote {len(filtered_swaps)} swaps to swaps_with_cex.json")
