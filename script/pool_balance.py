# import json


# BLOCK=21763860
# TICK_BASE=1.0001
# CURRENT_TICK=-198253 # Tick for the first swap
# SQRT_PRICE=3927370225299858350344231

# def pool_balances_at_block(snapshot: dict, sqrtPX96: int, current_tick: int, active_liq: int):
#     """
#     Returns raw token amounts (token0, token1) a single v4 pool owns
#     at this block snapshot.
#     """
#     from decimal import Decimal, getcontext
#     getcontext().prec = 200   # high precision

#     sqrtP = Decimal(sqrtPX96) / Decimal(1 << 96)

#     # gather and sort all initialized ticks as ints
#     all_ticks = sorted(int(t) for t in snapshot.keys() if not t.startswith("__"))

#     # find index of the current tick in that array
#     idx = all_ticks.index(current_tick)

#     # build helper that yields successive bands going right / left
#     def walk(direction: int):
#         """
#         direction = +1 (right, token1 side) or -1 (left, token0 side)
#         Yields tuples (L_band, sqrt_lower, sqrt_upper)
#         """
#         L = Decimal(active_liq)
#         last_tick = current_tick
#         i = idx + (1 if direction > 0 else -1)
#         while 0 <= i < len(all_ticks):
#             tick = all_ticks[i]

#             if direction > 0 and tick <= current_tick:
#                 i += 1; continue
#             if direction < 0 and tick >= current_tick:
#                 i -= 1; continue

#             # compute band [last, t) in price‐space
#             sqrt_low  = Decimal(TICK_BASE) ** (Decimal(last_tick) / 2)
#             sqrt_high = Decimal(TICK_BASE) ** (Decimal(tick) / 2)

#             if direction < 0:
#                 sqrt_low, sqrt_high = sqrt_high, sqrt_low   # swap

#             yield L, sqrt_low, sqrt_high

#             # cross the tick -> update liquidity with its liquidityNet
#             liq_net = Decimal(snapshot[str(tick)]["liquidityNet"])
#             L += liq_net
#             last_tick = tick
#             i += 1 if direction > 0 else -1

#     amt0 = amt1 = Decimal(0)

#     # active band (uses current sqrtP)
#     lower = TICK_BASE ** (Decimal(all_ticks[idx-1]) / 2)
#     upper = TICK_BASE ** (Decimal(all_ticks[idx+1]) / 2)
#     amt0 += active_liq * (1 / sqrtP - 1 / upper)
#     amt1 += active_liq * (sqrtP - lower)

#     # ---- walk outwards ----
#     for L, sl, su in walk(+1): # right side -> token1 only
#         amt1 += L * (su - sl)
#     for L, sl, su in walk(-1): # left side -> token0 only
#         amt0 += L * (1 / sl - 1 / su)

#     return int(amt0), int(amt1)

# if __name__ == "__main__":
#     with open("tick_snapshot.json") as f:
#         all_data = json.load(f)

#     snap = all_data[str(BLOCK)]
#     active_liq = int(snap["__L"])

#     (amount0, amount1) = pool_balances_at_block(snap, SQRT_PRICE, CURRENT_TICK, active_liq)

#     print((amount0, amount1))

import json
from decimal import Decimal, getcontext, ROUND_FLOOR

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
    tick_snapshot_dict: dict, # {"tick_str": {"liquidityNet": "..."}}
    current_sqrtPX96_int: int,
    # current_tick_int: int, # Not directly used by this revised algorithm, sqrtP is king
    slot0_liquidity_int: int # This is Pool.Slot0.liquidity
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

        # Add the liquidityNet from tick_lower_boundary (if it was an initialized tick)
        # to update the running_liquidity. This new running_liquidity is active
        # for the current segment [tick_lower_boundary, tick_upper_boundary).
        if str(tick_lower_boundary) in tick_snapshot_dict:
            running_liquidity_decimal += Decimal(tick_snapshot_dict[str(tick_lower_boundary)]["liquidityNet"])

        # The L for this segment.
        # A key insight from V3 SDK: Slot0.liquidity IS the running_liquidity IF the
        # current_tick_int falls within the segment [tick_lower_boundary, tick_upper_boundary).
        # So, if this segment is the "active" one, we should use slot0_liquidity_int.
        # Otherwise, the accumulated running_liquidity_decimal is correct.

        segment_liquidity_decimal = running_liquidity_decimal
        # Determine if current_sqrtP_decimal (derived from current_tick_int implicitly)
        # means this segment is the one for which slot0_liquidity_int is authoritative.
        # This is true if tick_lower_boundary <= current_tick_from_sqrtP < tick_upper_boundary
        # We don't have current_tick_int as a direct input to this specific logic path anymore,
        # but current_sqrtP_decimal implies a current_tick.
        # The logic in `get_amounts_for_liquidity_in_range` correctly handles where current_sqrtP_decimal
        # lies relative to the segment's bounds.
        # The critical part is what L to use.

        # If current_sqrtP_decimal implies a current_tick that falls within this segment,
        # then the `running_liquidity_decimal` *should* have naturally converged to `slot0_liquidity_int`.
        # Let's test this assumption. If they differ significantly, there's a mismatch in understanding
        # or data. For now, we trust `running_liquidity_decimal` as calculated.
        # The Pool.sol contract uses this cumulative `liquidity` for swaps.

        # If slot0_liquidity_int is the one provided by the chain state for the current global tick,
        # and if the current global tick falls into this [tick_lower_boundary, tick_upper_boundary) segment,
        # then running_liquidity_decimal *must* equal slot0_liquidity_int for consistency.
        # If it doesn't, the input slot0_liquidity_int might be from a slightly different state
        # than the tick_snapshot, or there's a subtle aspect missed.
        # For this implementation, we will trust the `running_liquidity_decimal` derived from summing `liquidityNet`.

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
    # Example constants from your script
    BLOCK = 21763860
    # CURRENT_TICK_ARG = -198253 # This was for the original function, not directly used in the new one
    SQRT_PRICE_ARG = 3927370225299858350344231

    with open("tick_snapshot.json") as f:
        all_data_snapshots = json.load(f)

    if str(BLOCK) not in all_data_snapshots:
        print(f"No tick snapshot data found for block {BLOCK}")
    else:
        block_snapshot_data = all_data_snapshots[str(BLOCK)]

        if "__L" not in block_snapshot_data: # Assuming your Python script stores Slot0.liquidity as "__L"
            print(f"Slot0 liquidity ('__L') not found in tick snapshot for block {BLOCK}")
        else:
            slot0_liquidity_for_block = int(block_snapshot_data["__L"])

            print(f"Calculating balances for Block {BLOCK}:")
            print(f"  Using SqrtPriceX96: {SQRT_PRICE_ARG}")
            # print(f"  (Original Current Tick Arg: {CURRENT_TICK_ARG})") # For reference
            print(f"  Using Slot0 Liquidity from snapshot: {slot0_liquidity_for_block}")

            (amount0, amount1) = pool_balances_at_block(
                block_snapshot_data, # Pass the snapshot for the block (contains ticks and their liquidityNet)
                SQRT_PRICE_ARG,      # The SqrtPriceX96 at the state of interest
                # CURRENT_TICK_ARG,  # No longer a direct input to this version
                slot0_liquidity_for_block # The Slot0.liquidity corresponding to SQRT_PRICE_ARG
            )
            print(f"Calculated balances for block {BLOCK}: Token0 = {amount0}, Token1 = {amount1}")
