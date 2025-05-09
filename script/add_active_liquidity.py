import asyncio
import json
from web3 import AsyncWeb3, AsyncHTTPProvider, Web3
from eth_abi.packed import encode_packed
from eth_typing import HexStr

# --- Config ---
RPC = "https://mainnet.chainnodes.org/cbc45c0d-ad5a-4bdf-9f9d-22228f8199f6"
POOLMAN_ADDR = "0x000000000004444c5dc75cB358380D2e3dE08A90"
POOL_ID_HEX = "0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27"
TICK_SNAPSHOT_FILE = "tick_snapshot.json"

w3_async = AsyncWeb3(AsyncHTTPProvider(RPC))
w3_sync = Web3()

def calculate_mapping_slot(key_hex, mapping_slot_index) -> HexStr:
    key_bytes = bytes.fromhex(key_hex[2:])
    slot_bytes = mapping_slot_index.to_bytes(32, 'big')
    encoded = encode_packed(['bytes32', 'bytes32'], [key_bytes, slot_bytes])
    slot_hash = w3_sync.keccak(encoded)
    return HexStr(slot_hash.hex())

def decode_slot0_liquidity(slot_value_bytes: bytes) -> int:
    return int.from_bytes(slot_value_bytes[16:], 'big', signed=False)

async def add_active_liquidity():
    with open(TICK_SNAPSHOT_FILE) as f:
        tick_snapshot = json.load(f)

    # Normalize keys to strings
    tick_snapshot = {str(k): v for k, v in tick_snapshot.items()}

    pool_base = calculate_mapping_slot(POOL_ID_HEX, 6)
    liquidity_slot = HexStr(hex(int(pool_base, 16) + 3))

    updated_count = 0

    for block_str, data in tick_snapshot.items():
        if "__L" in data:
            print(f"[skip] Block {block_str} already has __L")
            continue
        try:
            liq_bytes = await w3_async.eth.get_storage_at(
                POOLMAN_ADDR, liquidity_slot, block_identifier=int(block_str)
            )
            active_liq = decode_slot0_liquidity(liq_bytes)
            tick_snapshot[block_str]["__L"] = str(active_liq)
            updated_count += 1
            print(f"[✓] Block {block_str}: __L = {active_liq}")
        except Exception as e:
            print(f"[!] Error fetching block {block_str}: {e}")

    # Save updated file
    with open(TICK_SNAPSHOT_FILE, "w") as f:
        json.dump(tick_snapshot, f, indent=2)

    print(f"\nAdded __L to {updated_count} blocks.")

if __name__ == "__main__":
    asyncio.run(add_active_liquidity())
