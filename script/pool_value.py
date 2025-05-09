import json
import csv
from decimal import Decimal, getcontext, ROUND_FLOOR

TICK_SNAPSHOT_JSON_FILE="tick_snapshot.json"
SWAPS_JSON_FILE="swaps-v4.json"

METRICS_PATH = "./storage/metrics.csv"
OUTPUT_PATH = "./storage/metrics_with_value.csv"

# Uniswap V3/V4 constants
MIN_TICK = -887272
MAX_TICK = 887272
Q96 = Decimal(1 << 96)

def get_sqrt_ratio_at_tick(tick: int) -> Decimal:
    if not (MIN_TICK <= tick <= MAX_TICK):
        raise ValueError(f"Tick {tick} is out of bounds [{MIN_TICK}, {MAX_TICK}]")
    # price(i) = 1.0001^i, so sqrtPrice(i) = 1.0001^(i/2)
    return Decimal("1.0001")**(Decimal(tick) / Decimal(2))

def get_amounts_for_liquidity_in_range(
    sqrt_price_current_decimal: Decimal,
    sqrt_price_lower_bound_decimal: Decimal,
    sqrt_price_upper_bound_decimal: Decimal,
    liquidity_decimal: Decimal
) -> tuple[Decimal, Decimal]:
    amount0 = Decimal(0)
    amount1 = Decimal(0)

    if liquidity_decimal <= 0: # No liquidity, no amounts
        return amount0, amount1

    # Ensure lower_bound <= upper_bound
    sp_low = min(sqrt_price_lower_bound_decimal, sqrt_price_upper_bound_decimal)
    sp_high = max(sqrt_price_lower_bound_decimal, sqrt_price_upper_bound_decimal)

    if sqrt_price_current_decimal < sp_low:
        # Price is below the range, liquidity is all token0
        amount0 = liquidity_decimal * ( (Decimal(1) / sp_low) - (Decimal(1) / sp_high) )
    elif sqrt_price_current_decimal >= sp_high:
        # Price is above the range, liquidity is all token1
        amount1 = liquidity_decimal * (sp_high - sp_low)
    else:
        # Price is within the range, liquidity is mixed
        amount0 = liquidity_decimal * ( (Decimal(1) / sqrt_price_current_decimal) - (Decimal(1) / sp_high) )
        amount1 = liquidity_decimal * (sqrt_price_current_decimal - sp_low)

    return amount0, amount1

def pool_balances_at_block(
    tick_snapshot_dict: dict,
    current_sqrtPX96_int: int,
    slot0_liquidity_int: int
):
    getcontext().prec = 78 # Sufficient precision

    current_sqrtP_decimal = Decimal(current_sqrtPX96_int) / Q96

    total_amount0 = Decimal(0)
    total_amount1 = Decimal(0)

    # Extract initialized ticks from snapshot, convert to int, and sort.
    # Filter out special keys like "__L" (which is slot0_liquidity_int)
    initialized_ticks_int = sorted([
        int(t_str) for t_str in tick_snapshot_dict.keys() if not t_str.startswith("__")
    ])

    # Create a comprehensive list of all tick boundaries for segments.
    # Includes MIN_TICK, MAX_TICK, and all unique initialized ticks.
    all_segment_boundaries = sorted(list(set([MIN_TICK, MAX_TICK] + initialized_ticks_int)))

    # This will track the cumulative liquidity active as we sweep from left to right.
    # It starts at 0 because liquidityNet at MIN_TICK is conceptually 0 or handled by first init tick.
    running_liquidity_decimal = Decimal(0)

    # Iterate through all defined segments [tick_lower, tick_upper)
    for i in range(len(all_segment_boundaries) - 1):
        tick_lower_boundary = all_segment_boundaries[i]
        tick_upper_boundary = all_segment_boundaries[i+1]

        if tick_lower_boundary >= tick_upper_boundary: # Skip invalid or zero-width segments
            continue

        if str(tick_lower_boundary) in tick_snapshot_dict:
            running_liquidity_decimal += Decimal(tick_snapshot_dict[str(tick_lower_boundary)]["liquidityNet"])

        segment_liquidity_decimal = running_liquidity_decimal
        if segment_liquidity_decimal > 0: # Or slightly > 0 to handle potential float dust
            sqrt_p_lower_segment = get_sqrt_ratio_at_tick(tick_lower_boundary)
            sqrt_p_upper_segment = get_sqrt_ratio_at_tick(tick_upper_boundary)

            amount0_in_segment, amount1_in_segment = get_amounts_for_liquidity_in_range(
                current_sqrtP_decimal,
                sqrt_p_lower_segment,
                sqrt_p_upper_segment,
                segment_liquidity_decimal
            )
            total_amount0 += amount0_in_segment
            total_amount1 += amount1_in_segment

    return int(total_amount0.to_integral_value(rounding=ROUND_FLOOR)), \
           int(total_amount1.to_integral_value(rounding=ROUND_FLOOR))


if __name__ == "__main__":
    metrics_rows = []
    try:
        with open(METRICS_PATH, 'r') as f:
            reader = csv.DictReader(f)
            metrics_rows = list(reader)
    except FileNotFoundError:
        print(f"Error: Metrics file {METRICS_PATH} not found.")

    # Load swaps JSON for sqrtPriceX96 values
    try:
        with open(SWAPS_JSON_FILE, 'r') as f:
            swaps_data = json.load(f)
            swaps_list = swaps_data["data"]["pool"]["swaps"]
    except (FileNotFoundError, KeyError) as e:
        print(f"Error loading swaps data: {e}")

    # Create a mapping of block number to sqrtPriceX96 from swaps data
    block_to_sqrtprice = {}
    for swap in swaps_list:
        block_num = swap["transaction"]["blockNumber"]
        sqrtprice = swap["sqrtPriceX96"]
        block_to_sqrtprice[block_num] = sqrtprice

    # Load tick snapshots
    try:
        with open(TICK_SNAPSHOT_JSON_FILE, 'r') as f:
            all_tick_snapshots = json.load(f)
    except FileNotFoundError:
        print(f"Error: Tick snapshot file {TICK_SNAPSHOT_JSON_FILE} not found.")

    # Process each row and add pool value
    with open(OUTPUT_PATH, 'w', newline='') as f_out:
        # Add pool_value to the headers
        fieldnames = list(metrics_rows[0].keys()) + ['pool_value']
        writer = csv.DictWriter(f_out, fieldnames=fieldnames)
        writer.writeheader()

        for row in metrics_rows:
            block_num = row['blk']

            # Get the sqrtPriceX96 from swaps file
            if block_num not in block_to_sqrtprice:
                print(f"Warning: Block {block_num} not found in swaps data")
                row['pool_value'] = "N/A"
                writer.writerow(row)
                continue

            sqrtPriceX96 = int(block_to_sqrtprice[block_num])

            # Check if we have tick snapshot data for this block
            if block_num not in all_tick_snapshots:
                print(f"Warning: No tick snapshot data found for block {block_num}")
                row['pool_value'] = "N/A"
                writer.writerow(row)
                continue

            # Get the tick snapshot data for this block
            block_snapshot_data = all_tick_snapshots[block_num]

            # Check if we have liquidity data
            if "__L" not in block_snapshot_data:
                print(f"Warning: Slot0 liquidity ('__L') not found in tick snapshot for block {block_num}")
                row['pool_value'] = "N/A"
                writer.writerow(row)
                continue

            # Get the liquidity value
            slot0_liquidity = int(block_snapshot_data["__L"])

            # Calculate pool balances using existing function
            amount0, amount1 = pool_balances_at_block(
                block_snapshot_data,
                sqrtPriceX96,
                slot0_liquidity
            )

            # Calculate pool value using the formula
            # P_0 = (sqrtPrice/2^96)^2
            # V = (P_0 * token0 + token1) * 10^-6
            P_0 = (Decimal(sqrtPriceX96) / Q96) ** 2
            total_pool_value = (P_0 * Decimal(amount0) + Decimal(amount1)) * Decimal('0.000001')
            formatted_pool_value = f"{total_pool_value:.2f}" # Limit to 2 decimals

            # Add pool value to the row
            row['pool_value'] = str(formatted_pool_value)
            writer.writerow(row)

    print(f"Metrics with pool value written to {OUTPUT_PATH}")
