import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns

# Read the CSV file
df = pd.read_csv('storage/metrics.csv')

# Create a figure with subplots
fig, axs = plt.subplots(3, 1, figsize=(12, 15))

# 1. Plot Expected vs Actual Fees
axs[0].plot(df['idx'], df['expected_fee'], 'b-', label='Expected Fee')
axs[0].plot(df['idx'], df['actual_fee'], 'r-', label='Actual Fee')
axs[0].fill_between(df['idx'], df['expected_fee'], df['actual_fee'],
                alpha=0.2, color='purple')
axs[0].set_xlabel('Swap Index')
axs[0].set_ylabel('Fee (in bps)')
axs[0].set_title('Expected vs Actual Fees')
axs[0].legend()
axs[0].grid(True, alpha=0.3)

# 2. Plot Fee Carry (Error)
axs[1].plot(df['idx'], df['carry'], 'g-')
axs[1].axhline(y=0, color='r', linestyle='-', alpha=0.3)
axs[1].fill_between(df['idx'], df['carry'], 0,
                alpha=0.2, color='green', where=(df['carry'] > 0))
axs[1].fill_between(df['idx'], df['carry'], 0,
                alpha=0.2, color='red', where=(df['carry'] < 0))
axs[1].set_xlabel('Swap Index')
axs[1].set_ylabel('Carry (Error)')
axs[1].set_title('Fee Calculation Error (Carry)')
axs[1].grid(True, alpha=0.3)

# 3. Calculate cumulative carry over time
df['cumulative_carry'] = df['carry'].cumsum()
axs[2].plot(df['idx'], df['cumulative_carry'], 'b-', linewidth=2)
axs[2].axhline(y=0, color='r', linestyle='--', alpha=0.5)
axs[2].fill_between(df['idx'], df['cumulative_carry'], 0,
                 alpha=0.2, color='blue')
axs[2].set_xlabel('Swap Index')
axs[2].set_ylabel('Cumulative Carry')
axs[2].set_title('Accumulated Fee Error Over Time')
axs[2].grid(True, alpha=0.3)

# # Calculate statistics
# mean_error = df['carry'].mean()
# abs_mean_error = df['carry'].abs().mean()
# max_error = df['carry'].abs().max()
# std_dev = df['carry'].std()
# exact_match_pct = (df['carry'] == 0).mean() * 100
# within_1bps_pct = ((df['carry'].abs() <= 1)).mean() * 100
# within_5bps_pct = ((df['carry'].abs() <= 5)).mean() * 100

# summary = f"""
# Fee Accuracy Statistics:
# Mean Error: {mean_error:.2f}
# Absolute Mean Error: {abs_mean_error:.2f}
# Max Error: {max_error:.2f}
# Standard Deviation: {std_dev:.2f}

# Percentage of Swaps with:
# - Exact Fee Match: {exact_match_pct:.1f}%
# - Fee Error ≤ 1 bps: {within_1bps_pct:.1f}%
# - Fee Error ≤ 5 bps: {within_5bps_pct:.1f}%

# Final Cumulative Carry: {df['cumulative_carry'].iloc[-1]:.2f}
# """

# plt.figtext(0.5, 0.01, summary, ha='center', fontsize=10,
#            bbox=dict(facecolor='white', alpha=0.8))

# Adjust layout and save
plt.tight_layout(rect=[0, 0.1, 1, 0.98])
plt.suptitle('Fee Calculation Accuracy Analysis', fontsize=16)
plt.savefig('fee_accuracy.png', dpi=300, bbox_inches='tight')
plt.show()

# Bonus: Let's also look at price tracking accuracy
plt.figure(figsize=(12, 10))

# Price comparison plot
plt.subplot(2, 1, 1)
plt.plot(df['idx'], df['expected_price'], 'b-', label='Expected Price')
plt.plot(df['idx'], df['actual_price'], 'r-', label='Actual Price')
plt.fill_between(df['idx'], df['expected_price'], df['actual_price'],
                alpha=0.2, color='purple')
plt.xlabel('Swap Index')
plt.ylabel('USDC Price')
plt.title('Expected vs Actual USDC Price')
plt.legend()
plt.grid(True, alpha=0.3)

# Price error percentage
price_error_pct = ((df['actual_price'] - df['expected_price']) / df['expected_price']) * 100
plt.subplot(2, 1, 2)
plt.plot(df['idx'], price_error_pct, 'g-')
plt.axhline(y=0, color='r', linestyle='-', alpha=0.3)
plt.xlabel('Swap Index')
plt.ylabel('Price Error (%)')
plt.title('Price Difference Percentage')
plt.grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig('price_accuracy.png', dpi=300)
plt.show()

print("Analysis complete! Check the generated images for visualizations.")
