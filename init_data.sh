set -euo pipefail

POOL_ID=0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27
SLOT_INDEX_FOR_POOLS_MAPPING=6               # mapping(bytes32 ⇒ State) is at slot 6
MANAGER=0x000000000004444c5dc75cB358380D2e3dE08A90
RPC=https://eth.drpc.org
BLOCK=21763860

echo "Fetching pool state …"

##############################################################################
# 1. Base slot for this pool’s State struct                                  #
##############################################################################
BASE_SLOT=$(cast index bytes32 "$POOL_ID" "$SLOT_INDEX_FOR_POOLS_MAPPING")
BASE_SLOT_DEC=$(cast --to-dec "$BASE_SLOT")
echo "State struct starts at slot  $BASE_SLOT (dec $BASE_SLOT_DEC)"

##############################################################################
# 2. slot0 (works already, kept here for completeness)                       #
##############################################################################
SLOT0_RAW=$(cast storage "$MANAGER" "$BASE_SLOT" --rpc-url "$RPC" --block "$BLOCK")

LP_FEE_HEX=${SLOT0_RAW:8:6}
TICK_HEX=${SLOT0_RAW:20:6}
SQRT_PRICE_HEX=${SLOT0_RAW:26:40}

LP_FEE_DEC=$(cast --to-dec 0x$LP_FEE_HEX)

TICK_UNSIGNED_DEC=$(cast --to-dec 0x$TICK_HEX)
if (( TICK_UNSIGNED_DEC >= 8388608 )); then
  TICK_DEC=$((TICK_UNSIGNED_DEC - 16777216))
else
  TICK_DEC=$TICK_UNSIGNED_DEC
fi

SQRT_PRICE_DEC=$(cast --to-dec 0x$SQRT_PRICE_HEX)

echo "slot0 → lpFee $LP_FEE_DEC, tick $TICK_DEC, sqrtPriceX96 $SQRT_PRICE_DEC"

##############################################################################
# 3. liquidity is the *fourth* slot in State ⇒ offset 3                      #
#    (slot0, feeGrowth0, feeGrowth1, liquidity)                              #
##############################################################################
BASE_HEX_NO_PREFIX=${BASE_SLOT#0x}
BASE_HEX_UPPER=$(echo "$BASE_HEX_NO_PREFIX" | tr '[:lower:]' '[:upper:]')

LIQ_SLOT_HEX=$(echo "obase=16; ibase=16; $BASE_HEX_UPPER + 3" | bc)
LIQ_SLOT=$(printf "0x%064s" "$LIQ_SLOT_HEX" | sed 's/ /0/g')

RAW_LIQ=$(cast storage "$MANAGER" "$LIQ_SLOT_HEX" --rpc-url "$RPC" --block "$BLOCK")

# `uint128 liquidity` lives in the LOWER 16 bytes of the 32‑byte slot
LIQ_HEX=${RAW_LIQ: -32}
LIQ_DEC=$(cast --to-dec 0x$LIQ_HEX)

echo "liquidity slot        $LIQ_SLOT_HEX"
echo "raw storage           $RAW_LIQ"
echo "decoded liquidity     $LIQ_DEC (hex 0x$LIQ_HEX)"
