import pandas as pd, matplotlib.pyplot as plt

df = pd.read_csv("storage/metrics.csv")
plt.scatter((df["sumSq"]**0.5), df["feePpm"]/1e4, s=8)
plt.xlabel("realised σ (ticks)")
plt.ylabel("fee (%)")
plt.title("Hook fee vs realised volatility")
plt.tight_layout(); plt.show()
