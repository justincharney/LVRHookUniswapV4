set -euo pipefail

POOL_ID=0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27
SLOT_INDEX_FOR_POOLS_MAPPING=6               # mapping(bytes32 ⇒ State) is at slot 6
MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
RPC=https://eth.drpc.org
BLOCK=21763860 # Specific block where you know the state

echo "Fetching pool state at block $BLOCK …"


##############################################################################
# 1. Base slot for this pool’s State struct                                  #
##############################################################################
BASE_SLOT=$(cast index bytes32 "$POOL_ID" "$SLOT_INDEX_FOR_POOLS_MAPPING")
# BASE_SLOT_DEC=$(cast --to-dec "$BASE_SLOT") # Not strictly needed for calculations if using hex
echo "State struct starts at slot  $BASE_SLOT" # (dec $BASE_SLOT_DEC)"

##############################################################################
# 2. slot0 (works already, kept here for completeness)                       #
##############################################################################
SLOT0_RAW=$(cast storage "$MANAGER" "$BASE_SLOT" --rpc-url "$RPC" --block "$BLOCK")

# Extracting parts of the 0x-prefixed hex string from SLOT0_RAW
# String indices: 0x (chars 0,1), then hex data
# lpFee: bytes 3,4,5. Chars from index 2+(3*2)=8, length 3*2=6
LP_FEE_HEX_CHARS=${SLOT0_RAW:8:6}
# tick: bytes 9,10,11. Chars from index 2+(9*2)=20, length 3*2=6
TICK_HEX_CHARS=${SLOT0_RAW:20:6}
# sqrtPriceX96: bytes 12-31. Chars from index 2+(12*2)=26, length 20*2=40
SQRT_PRICE_HEX_CHARS=${SLOT0_RAW:26:40}

LP_FEE_DEC=$(cast --to-dec "0x$LP_FEE_HEX_CHARS")

TICK_UNSIGNED_DEC=$(cast --to-dec "0x$TICK_HEX_CHARS")
if (( TICK_UNSIGNED_DEC >= 8388608 )); then # 2^23
  TICK_DEC=$((TICK_UNSIGNED_DEC - 16777216)) # 2^24
else
  TICK_DEC=$TICK_UNSIGNED_DEC
fi

SQRT_PRICE_DEC=$(cast --to-dec "0x$SQRT_PRICE_HEX_CHARS")

echo "slot0 → lpFee $LP_FEE_DEC, tick $TICK_DEC, sqrtPriceX96 $SQRT_PRICE_DEC"

##############################################################################
# 3. liquidity is the *fourth* slot in State ⇒ offset 3                      #
#    (slot0 (S+0), feeGrowth0 (S+1), feeGrowth1 (S+2), liquidity (S+3))      #
##############################################################################
BASE_HEX_NO_PREFIX=${BASE_SLOT#0x}
# Ensure uppercase for bc consistency, though many versions handle lowercase
BASE_HEX_UPPER=$(echo "$BASE_HEX_NO_PREFIX" | tr '[:lower:]' '[:upper:]')

# Calculate (S + 3) in hex. bc output will be raw hex digits (potentially uppercase)
LIQ_SLOT_HEX_FROM_BC=$(echo "obase=16; ibase=16; $BASE_HEX_UPPER + 3" | bc | tr -d '\n\r[:space:]')

# Prepare the slot for cast: needs "0x" prefix and be 64 hex digits
LIQ_SLOT_FOR_CAST=$(printf "0x%064s" "$LIQ_SLOT_HEX_FROM_BC" | sed 's/ /0/g')

RAW_LIQ=$(cast storage "$MANAGER" "$LIQ_SLOT_FOR_CAST" --rpc-url "$RPC" --block "$BLOCK")

# `uint128 liquidity` lives in the LOWER 16 bytes of the 32-byte slot
# RAW_LIQ is "0x" + 64 hex chars. Last 32 hex chars are the lower 16 bytes.
# String index: 66 total chars. Last 32 chars start at index 66-32 = 34.
LIQ_HEX_CHARS=${RAW_LIQ:34:32}
LIQ_DEC=$(cast --to-dec "0x$LIQ_HEX_CHARS") # Add 0x for cast --to-dec

echo "liquidity slot (calculated, S+3) $LIQ_SLOT_FOR_CAST"
echo "raw storage from that slot     $RAW_LIQ"
echo "decoded liquidity              $LIQ_DEC (hex 0x$LIQ_HEX_CHARS)"
