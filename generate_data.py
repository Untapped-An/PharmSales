"""
Territory Data Generator -- Stage 1 of 2
==========================================
Produces accounts.csv and reps.csv: 620 synthetic pharma accounts across 50
reps in 5 regions, with a deliberately uneven ORIGINAL assignment (senior
reps in each region get 1.6x weight -- simulates realistic legacy drift).

Revenue potential is drawn log-normal (mean=9.0, sigma=0.55, clipped to
$2,000-$100,000) because real account/prescriber value is right-skewed --
a few large accounts, many small ones.

Next stage: rebalance_algorithm.py reads this output and produces
rebalanced_rep_id.
"""
import random
import pandas as pd
import numpy as np

random.seed(7)
np.random.seed(7)

REGIONS = ["Northeast", "Southeast", "Midwest", "Southwest", "West"]
N_REPS = 50
reps = []
for i in range(1, N_REPS + 1):
    region = REGIONS[(i - 1) % len(REGIONS)]
    reps.append({"rep_id": i, "rep_name": f"Rep_{i:02d}", "region": region})
reps_df = pd.DataFrame(reps)

N_ACCOUNTS = 620
account_ids = [f"ACC{str(i).zfill(4)}" for i in range(1, N_ACCOUNTS + 1)]
regions_for_accounts = [random.choice(REGIONS) for _ in range(N_ACCOUNTS)]
revenue_potential = np.round(np.random.lognormal(mean=9.0, sigma=0.55, size=N_ACCOUNTS), -2)
revenue_potential = np.clip(revenue_potential, 2000, 100000)

accounts_df = pd.DataFrame({
    "account_id": account_ids,
    "region": regions_for_accounts,
    "revenue_potential": revenue_potential.astype(int),
})

# ---- ORIGINAL (mildly unbalanced) assignment: realistic legacy drift, not extreme ----
def assign_original(accounts_df, reps_df):
    assignment = []
    region_reps = {r: reps_df[reps_df.region == r].rep_id.tolist() for r in REGIONS}
    for _, row in accounts_df.iterrows():
        region = row.region
        reps_in_region = region_reps[region]
        n = len(reps_in_region)
        # mild skew: senior (first 40%) reps get 1.6x weight vs rest
        weights = [1.6 if idx < max(1, int(n * 0.4)) else 1.0 for idx in range(n)]
        rep_id = random.choices(reps_in_region, weights=weights, k=1)[0]
        assignment.append(rep_id)
    return assignment

accounts_df["original_rep_id"] = assign_original(accounts_df, reps_df)

# ---- REBALANCE: targeted, not full optimization ----
# Move accounts only from reps whose load is notably above their regional peers to reps
# notably below — mirrors how an analyst would actually redraw a few territory lines,
# not a from-scratch optimal reassignment.
def rebalance(accounts_df, reps_df):
    df = accounts_df.copy()
    df["rebalanced_rep_id"] = df["original_rep_id"]
    for region in REGIONS:
        region_reps = reps_df[reps_df.region == region].rep_id.tolist()
        # compute current counts
        counts = df[df.region == region]["rebalanced_rep_id"].value_counts().reindex(region_reps, fill_value=0)
        mean_c, std_c = counts.mean(), counts.std(ddof=0)
        overloaded = counts[counts > mean_c + 0.6 * std_c].index.tolist()
        underloaded = counts[counts < mean_c - 0.6 * std_c].index.tolist()
        for over_rep in overloaded:
            # move the smallest-value accounts off the overloaded rep first (keep their best accounts)
            over_accts = df[(df.region == region) & (df.rebalanced_rep_id == over_rep)].sort_values("revenue_potential")
            n_to_move = int(counts[over_rep] - mean_c)
            move_ids = over_accts.head(max(n_to_move, 0)).account_id.tolist()
            for aid in move_ids:
                if not underloaded:
                    break
                target = min(underloaded, key=lambda r: counts[r])
                df.loc[df.account_id == aid, "rebalanced_rep_id"] = target
                counts[over_rep] -= 1
                counts[target] += 1
                if counts[target] >= mean_c:
                    underloaded.remove(target)
    return df["rebalanced_rep_id"]

accounts_df["rebalanced_rep_id"] = rebalance(accounts_df, reps_df)

accounts_df.to_csv("accounts.csv", index=False)
reps_df.to_csv("reps.csv", index=False)
print("Total accounts:", len(accounts_df))
print("Total revenue potential:", accounts_df.revenue_potential.sum())
