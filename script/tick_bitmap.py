import asyncio
import json
from web3 import AsyncWeb3, AsyncHTTPProvider, Web3 # Need Web3 for keccak sync
from eth_abi.packed import encode_packed
from eth_typing import HexStr
from typing import Dict

# --- Configuration ---
RPC = "https://eth.drpc.org"
POOLMAN_ADDR = "0x000000000004444c5dc75cB358380D2e3dE08A90"
POOL_ID_HEX = "0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27"
BLOCK = 21_763_859
SPACING = 10
CONCURRENCY = 100

# --- Constants based on V4 Layout ---
POOLS_MAPPING_SLOT_INDEX = 6
TICK_BITMAP_OFFSET = 5 # Pool.State.tickBitmap offset
TICKS_OFFSET = 4 # Pool.State.ticks offset

FILE_BITMAP = "bitmap_snapshot.json"

w3_async = AsyncWeb3(AsyncHTTPProvider(RPC))
w3_sync = Web3() # For keccak

# --- Helper Functions ---
def calculate_mapping_slot(key_hex, mapping_slot_index) -> HexStr:
    """Calculates storage slot for a mapping key."""
    # Ensure key is hex string without 0x, pad if needed? Abi encode needs types.
    # PoolId is bytes32, slot index is uint256 (represented as bytes32 in packed)
    key_bytes = bytes.fromhex(key_hex[2:])
    slot_bytes = mapping_slot_index.to_bytes(32, 'big')
    encoded = encode_packed(['bytes32', 'bytes32'], [key_bytes, slot_bytes])
    slot_hash = w3_sync.keccak(encoded)
    return HexStr(slot_hash.hex())

def calculate_nested_mapping_slot(key, mapping_base_slot_hex) -> HexStr:
    """Calculates slot for key within a mapping already located at mapping_base_slot_hex."""
    # Key type depends: int16 for bitmap word, int24 for tick
    # Pad key to 32 bytes for encoding
    if isinstance(key, int):
       key_bytes = key.to_bytes(32, 'big', signed=True) # Use signed for int16/int24
    else:
       raise TypeError("Key must be integer for tick/wordPos")

    base_slot_bytes = bytes.fromhex(mapping_base_slot_hex[2:])
    encoded = encode_packed(['bytes32', 'bytes32'], [key_bytes, base_slot_bytes])
    slot_hash = w3_sync.keccak(encoded)
    return HexStr(slot_hash.hex())

def decode_tickinfo_slot0(slot0_bytes: bytes) -> tuple[int, int]:
    """Decodes liquidityNet (int128) and liquidityGross (uint128) from TickInfo slot 0."""
    liq_net_bytes = slot0_bytes[:16] # Upper 16 bytes
    liq_gross_bytes = slot0_bytes[16:] # Lower 16 bytes
    liq_net = int.from_bytes(liq_net_bytes, 'big', signed=True)
    liq_gross = int.from_bytes(liq_gross_bytes, 'big', signed=False)
    return liq_net, liq_gross # Note: Solidity struct might have gross as int96, but slot is 128 bits

# --- Main Logic ---
async def main():
    print("Calculating base slots...")
    pool_state_base_slot = calculate_mapping_slot(POOL_ID_HEX, POOLS_MAPPING_SLOT_INDEX)
    print(f"Pool State Base Slot (S): {pool_state_base_slot}")

    tick_bitmap_mapping_base_slot_int = int(pool_state_base_slot, 16) + TICK_BITMAP_OFFSET
    tick_bitmap_mapping_base_slot = HexStr(hex(tick_bitmap_mapping_base_slot_int))
    print(f"Tick Bitmap Mapping Base Slot (S + {TICK_BITMAP_OFFSET}): {tick_bitmap_mapping_base_slot}")

    ticks_mapping_base_slot_int = int(pool_state_base_slot, 16) + TICKS_OFFSET
    ticks_mapping_base_slot = HexStr(hex(ticks_mapping_base_slot_int))
    print(f"Ticks Mapping Base Slot (S + {TICKS_OFFSET}): {ticks_mapping_base_slot}")


    # 1. Fetch Bitmap words
    print("Fetching tick bitmap words...")
    # The tick index i can be calculated taking the log, as i = log_{1.0001}(2^128) = 887272.7517970635.
    # This is why the maximum tick is 887272.
    minW = -887272 // SPACING // 256
    maxW =  887272 // SPACING // 256
    print(f"Word range: {minW} to {maxW}")

    bitmap_word_values = {} # Store wordPos -> value
    tasks = []
    semaphore = asyncio.Semaphore(CONCURRENCY) # Limit concurrent requests

    async def fetch_bitmap_word(word):
        async with semaphore:
            slot = calculate_nested_mapping_slot(word, tick_bitmap_mapping_base_slot)
            value_bytes = await w3_async.eth.get_storage_at(POOLMAN_ADDR, slot, block_identifier=BLOCK)
            value_int = int.from_bytes(value_bytes, 'big')
            if value_int != 0:
                 bitmap_word_values[word] = value_int
            # print(f"Word {word}: {'Non-zero' if value_int != 0 else 'Zero'}") # Verbose

    for word in range(minW, maxW + 1):
        tasks.append(fetch_bitmap_word(word))

    await asyncio.gather(*tasks)
    print(f"Found {len(bitmap_word_values)} non-zero bitmap words.")
    bitmap_data_to_save = [{"wordPos": k, "value": hex(v)} for k, v in bitmap_word_values.items()]
    bitmap_data_to_save.sort(key=lambda x: x['wordPos']) # Sort for consistency
    with open(FILE_BITMAP, "w") as f:
        json.dump(bitmap_data_to_save, f, indent=2)
    print(f"Saved bitmap data to {FILE_BITMAP}")

    # 2. Find Initialized Ticks
    initialized_ticks = []
    for word, bits in bitmap_word_values.items():
        for bit in range(256):
            if (bits >> bit) & 1:
                tick = (word * 256 + bit) * SPACING
                # Check against TickMath boundaries if needed (though source bitmap shouldn't have out-of-bounds)
                if -887272 <= tick <= 887272:
                     initialized_ticks.append(tick)

    initialized_ticks.sort()
    print(f"Total initialized ticks found: {len(initialized_ticks)}")
    # print(f"Sample Ticks: {initialized_ticks[:5]}...{initialized_ticks[-5:]}") # Print some samples


    # 3. Fetch TickInfo for each initialized tick
    print("Fetching TickInfo for initialized ticks...")
    tick_data = {} # Store tick -> (liqNet, liqGross, fee0, fee1)
    tasks = []

    async def fetch_tick_info(tick):
         async with semaphore:
            tick_info_base_slot = calculate_nested_mapping_slot(tick, ticks_mapping_base_slot)
            slot0_int = int(tick_info_base_slot, 16)
            slot1 = HexStr(hex(slot0_int + 1))
            slot2 = HexStr(hex(slot0_int + 2))

            results = await asyncio.gather(
                w3_async.eth.get_storage_at(POOLMAN_ADDR, tick_info_base_slot, block_identifier=BLOCK),
                w3_async.eth.get_storage_at(POOLMAN_ADDR, slot1, block_identifier=BLOCK),
                w3_async.eth.get_storage_at(POOLMAN_ADDR, slot2, block_identifier=BLOCK)
            )

            liq_net, liq_gross = decode_tickinfo_slot0(results[0])
            fee0 = int.from_bytes(results[1], 'big')
            fee1 = int.from_bytes(results[2], 'big')
            tick_data[tick] = (liq_net, liq_gross, fee0, fee1)
            # print(f"Tick {tick}: Net={liq_net}, Gross={liq_gross}") # Verbose

    for tick in initialized_ticks:
         tasks.append(fetch_tick_info(tick))

    await asyncio.gather(*tasks)
    print(f"Fetched TickInfo for {len(tick_data)} ticks.")

    # 4. Prepare snapshot (include gross + net, maybe fees if needed)
    snap = [
        {"tick": t, "liquidityNet": data[0], "liquidityGross": data[1]} # Add Gross
        for t, data in tick_data.items()
        # Optionally keep filtering if net=0 and gross=0? Usually net != 0 if gross != 0
        if data[0] != 0 or data[1] != 0
    ]
    snap.sort(key=lambda x: x['tick']) # Sort by tick

    # 5. Save to JSON
    output_filename = "tick_snapshot.json"
    with open(output_filename, "w") as f:
        json.dump(snap, f, indent=2)
    print(f"Wrote {output_filename}")

# --- Run ---
if __name__ == "__main__":
    asyncio.run(main())
