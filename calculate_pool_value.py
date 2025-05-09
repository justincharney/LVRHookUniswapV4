from decimal import Decimal, getcontext

# Set high precision for our calculations
getcontext().prec = 50

# Given values
token0_balance = Decimal('62727680089951860105')
token1_balance = Decimal('147187323571')
sqrt_price_x96 = Decimal('3927370225299858350344231')
liquidity = Decimal('1179919373798284')

# Calculate Price_x from SqrtPriceX96
# Price = (SqrtPriceX96 / 2^96)²
pow2_96 = Decimal(2) ** 96
sqrt_price = sqrt_price_x96 / pow2_96
price_x = sqrt_price ** 2

# Calculate pool value using formula: Price_x * x + y
pool_value = price_x * token0_balance + token1_balance

# Print results
print(f"Token0 Balance: {token0_balance}")
print(f"Token1 Balance: {token1_balance}")
print(f"SqrtPriceX96: {sqrt_price_x96}")
print(f"Calculated Price_x: {price_x}")
print(f"Pool Value: {pool_value}")

# Optional: Convert to more readable format if these are in wei or similar small units
# Assuming 18 decimals for both tokens
print(f"\nCalculated Price_x (decimal): {price_x}")
print(f"Pool Value (decimal): {pool_value}")