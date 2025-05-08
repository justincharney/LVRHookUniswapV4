

We have swap...

Use Swap to get 
========================================
SWAP 1 No hook:
1 ETH 
for 1000 USDC.

fee = 0.05
AMM price == 1000 * 1.0005 = 1005
CEX price == 1020
LVR = 20
Fees = 5
=======================================

=======================================
SWAP 1 Hook:

SQRTPRICE BEFORE = KNOWN
LIQUIDITY ... NOT KNOWN ???? - Maybe known

1 ETH 
AMM price = 1005
CEX price = 1020

Fee = 15

for 1000 USDC.

fee = 0.01
AMM price == 1000 * 1.0005 = 1005


=======================================
SWAP 2 Hook:

SQRTPRICE BEFORE = KNOWN - from previoius swap SWQRTPRICE
LIQUIDITY ... NOT KNOWN ???? - Maybe known -- SCRAPEC

1 ETH 
AMM price = 1005
CEX price = 1020

Fee = 15

for 1000 USDC.

fee = 0.01
AMM price == 1000 * 1.0005 = 1005