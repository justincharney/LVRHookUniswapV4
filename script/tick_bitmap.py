import asyncio
import json
import os
from web3 import AsyncWeb3, AsyncHTTPProvider, Web3
from eth_abi.packed import encode_packed
from eth_typing import HexStr

# --- Configuration ---
RPC = "https://eth.drpc.org"
POOLMAN_ADDR = "0x000000000004444c5dc75cB358380D2e3dE08A90"
POOL_ID_HEX = "0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27"
SPACING = 10
CONCURRENCY = 100
SWAPS_FILE = "swaps-v4.json"

w3_async = AsyncWeb3(AsyncHTTPProvider(RPC))
w3_sync = Web3()

def calculate_mapping_slot(key_hex, mapping_slot_index) -> HexStr:
    key_bytes = bytes.fromhex(key_hex[2:])
    slot_bytes = mapping_slot_index.to_bytes(32, 'big')
    encoded = encode_packed(['bytes32', 'bytes32'], [key_bytes, slot_bytes])
    slot_hash = w3_sync.keccak(encoded)
    return HexStr(slot_hash.hex())

def calculate_nested_mapping_slot(key, mapping_base_slot_hex) -> HexStr:
    key_bytes = key.to_bytes(32, 'big', signed=True)
    base_slot_bytes = bytes.fromhex(mapping_base_slot_hex[2:])
    encoded = encode_packed(['bytes32', 'bytes32'], [key_bytes, base_slot_bytes])
    return HexStr(w3_sync.keccak(encoded).hex())

def decode_tickinfo_slot0(slot0_bytes: bytes) -> tuple[int, int]:
    return (
        int.from_bytes(slot0_bytes[:16], 'big', signed=True),
        int.from_bytes(slot0_bytes[16:], 'big')
    )

async def snapshot_at_block(block: int, tick_bitmap_base, ticks_base, all_bitmaps, all_ticks):
    block_str = str(block)
    if block_str in all_bitmaps and block_str in all_ticks:
        print(f"Skipping block {block} (already cached)")
        return

    print(f"Processing block {block}...")
    minW = -887272 // SPACING // 256
    maxW =  887272 // SPACING // 256
    bitmap_word_values = {}
    semaphore = asyncio.Semaphore(CONCURRENCY)

    async def fetch_bitmap_word(word):
        async with semaphore:
            slot = calculate_nested_mapping_slot(word, tick_bitmap_base)
            val_bytes = await w3_async.eth.get_storage_at(POOLMAN_ADDR, slot, block_identifier=block)
            val = int.from_bytes(val_bytes, 'big')
            if val != 0:
                bitmap_word_values[word] = val

    await asyncio.gather(*(fetch_bitmap_word(w) for w in range(minW, maxW + 1)))
    all_bitmaps[block_str] = {str(k): hex(v) for k, v in bitmap_word_values.items()}
    with open("bitmap_snapshot.json", "w") as f:
        json.dump(all_bitmaps, f, indent=2)

    initialized_ticks = []
    for word, bits in bitmap_word_values.items():
        for bit in range(256):
            if (bits >> bit) & 1:
                tick = (word * 256 + bit) * SPACING
                if -887272 <= tick <= 887272:
                    initialized_ticks.append(tick)

    tick_data = {}
    async def fetch_tick(tick):
        async with semaphore:
            base = calculate_nested_mapping_slot(tick, ticks_base)
            slot1 = HexStr(hex(int(base, 16) + 1))
            slot2 = HexStr(hex(int(base, 16) + 2))
            slot0, _, _ = await asyncio.gather(
                w3_async.eth.get_storage_at(POOLMAN_ADDR, base, block_identifier=block),
                w3_async.eth.get_storage_at(POOLMAN_ADDR, slot1, block_identifier=block),
                w3_async.eth.get_storage_at(POOLMAN_ADDR, slot2, block_identifier=block),
            )
            liq_net, liq_gross = decode_tickinfo_slot0(slot0)
            tick_data[tick] = {"liquidityNet": str(liq_net), "liquidityGross": str(liq_gross)}

    await asyncio.gather(*(fetch_tick(t) for t in initialized_ticks))
    all_ticks[block_str] = tick_data
    with open("tick_snapshot.json", "w") as f:
        json.dump(all_ticks, f, indent=2)

    print(f"Block {block} stored ({len(bitmap_word_values)} bitmap words, {len(tick_data)} ticks)")

async def main():
    with open(SWAPS_FILE) as f:
        blocks = sorted({int(s["transaction"]["blockNumber"]) for s in json.load(f)["data"]["pool"]["swaps"]})

    for fname in ("bitmap_snapshot.json", "tick_snapshot.json"):
        if not os.path.exists(fname):
            with open(fname, "w") as f:
                json.dump({}, f)

    with open("bitmap_snapshot.json") as f:
        all_bitmaps = json.load(f)
    with open("tick_snapshot.json") as f:
        all_ticks = json.load(f)

    pool_base = calculate_mapping_slot(POOL_ID_HEX, 6)
    tick_bitmap_base = HexStr(hex(int(pool_base, 16) + 5))
    ticks_base = HexStr(hex(int(pool_base, 16) + 4))

    for block in blocks:
        try:
            await snapshot_at_block(block, tick_bitmap_base, ticks_base, all_bitmaps, all_ticks)
        except Exception as e:
            print(f"[ERROR] Block {block} failed: {e}")

if __name__ == "__main__":
    asyncio.run(main())
