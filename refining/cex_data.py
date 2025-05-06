import requests
import pandas as pd
import time
from datetime import datetime, timedelta

'''
Fetches minute-level ETH/USDC price data from Coinbase. 
Interpolates to 1s granularity with linear interpolation.
Saves to eth_usdc_coinbase_prices_1s.csv.
'''

# Gets 1-min CEX data from Coinbase API
def fetch_coinbase_prices(product_id, start_iso, end_iso, granularity=60):
    url = f"https://api.exchange.coinbase.com/products/{product_id}/candles"
    params = {"start": start_iso, "end": end_iso, "granularity": granularity}
    r = requests.get(url, params=params)
    r.raise_for_status()
    data = r.json()

    # Returns columns: [time, low, high, open, close, volume]
    df = pd.DataFrame(data, columns=["timestamp_unix", "low", "high", "open", "close", "volume"])
    df["timestamp_unix"] = df["timestamp_unix"].astype(int)

    # Prunes df for only timestamp and close price
    df = df[["timestamp_unix", "close"]]
    return df.sort_values("timestamp_unix")


def fetch_all_prices(start_time, end_time, product_id="ETH-USDC"):

    # Limited by Coinbase API for data request --> query in 4 hour chunks
    all_data = []
    chunk_size = timedelta(hours=4) 
    current = start_time

    # Loop over time intervals to get each chunk
    while current < end_time:
        next_time = min(current + chunk_size, end_time)
        print(f"Fetching from {current} to {next_time}...")
        df = fetch_coinbase_prices(product_id=product_id, start_iso=current.isoformat(), end_iso=next_time.isoformat())
        all_data.append(df)
        current = next_time
        time.sleep(1)

    return pd.concat(all_data, ignore_index=True)

# Time range needed for swaps_with_timestamp.json data
start = datetime.fromisoformat("2021-05-05T00:00:00")
end = datetime.fromisoformat("2021-05-08T00:00:00")


# Run
df = fetch_all_prices(start, end)

# Interpolate to 1s granularity
df["timestamp"] = pd.to_datetime(df["timestamp_unix"], unit="s")                # Converts timestamps to datetime
df = df.drop_duplicates(subset="timestamp")                                     # Drops duplicate timestamps
df = df.set_index("timestamp").sort_index()                                     # Sets timestamp as index for resampling
df_interp = df["close"].resample("1s").interpolate("linear").reset_index()      # Resamples 1s intervals using linear interpolation
df_interp["cex_timestamp"] = df_interp["timestamp"].astype(int) // 10**9        # Converts back to unix seconds
df_interp = df_interp.rename(columns={"close": "cex_price"})                    # Renames columns
df_interp = df_interp[["cex_timestamp", "cex_price"]]                           # Final DF

# Save interpolated data
df_interp.to_csv("eth_usdc_coinbase_prices_1s.csv", index=False)
print("Saved interpolated CEX prices:")
print(df_interp.head())
