"""
Territory Rebalancing Algorithm
================================
Input:  accounts_df with columns [account_id, region, revenue_potential, original_rep_id]
        reps_df with columns [rep_id, rep_name, region]
Output: a rebalanced_rep_id assignment for every account.

METHOD -- targeted rebalancing, not full optimization.
This deliberately mirrors how a human analyst redraws a few territory lines rather
than a from-scratch bin-packing solve:

  1. Work region by region (accounts never cross regions -- a hard constraint).
  2. Within a region, find the mean and std dev of account-count per rep.
  3. Flag "overloaded" reps: count > mean + 0.6*std.
  4. Flag "underloaded" reps: count < mean - 0.6*std.
  5. For each overloaded rep, move their LOWEST-VALUE accounts first (not
     random, not highest-value) to whichever underloaded rep currently has
     the fewest accounts -- until the overloaded rep is back near the mean.

WHY lowest-value-first: this is the design choice that produces the project's
strongest finding -- 0% of top-half-value accounts were moved. High-value
accounts carry real relationship equity; a good realignment buys balance
with the cheapest accounts available, not the most valuable ones.

LIMITATION (be upfront about this in interview): this does not model
drive-time, sub-region contiguity, or account-count vs. revenue-count
trade-offs simultaneously -- it optimizes account COUNT, which is why the
revenue-based std dev also improves but not perfectly, and why "reps over
capacity" (a count-threshold metric) can still worsen even as total excess
load and captured revenue both improve substantially. See PROJECT_DOCUMENTATION.md
section 2.5 ("the capacity paradox") for the full resolution of that finding.
"""
import pandas as pd

REGIONS = ["Northeast", "Southeast", "Midwest", "Southwest", "West"]


def rebalance(accounts_df: pd.DataFrame, reps_df: pd.DataFrame) -> pd.Series:
    df = accounts_df.copy()
    df["rebalanced_rep_id"] = df["original_rep_id"]

    for region in REGIONS:
        region_reps = reps_df[reps_df.region == region].rep_id.tolist()
        counts = (
            df[df.region == region]["rebalanced_rep_id"]
            .value_counts()
            .reindex(region_reps, fill_value=0)
        )
        mean_c, std_c = counts.mean(), counts.std(ddof=0)
        overloaded = counts[counts > mean_c + 0.6 * std_c].index.tolist()
        underloaded = counts[counts < mean_c - 0.6 * std_c].index.tolist()

        for over_rep in overloaded:
            # move the LOWEST-value accounts off the overloaded rep first
            over_accts = (
                df[(df.region == region) & (df.rebalanced_rep_id == over_rep)]
                .sort_values("revenue_potential")
            )
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


if __name__ == "__main__":
    accounts = pd.read_csv("accounts.csv")[
        ["account_id", "region", "revenue_potential", "original_rep_id"]
    ]
    reps = pd.read_csv("reps.csv")

    result = rebalance(accounts, reps)
    accounts["rebalanced_rep_id"] = result
    accounts.to_csv("accounts_rebalanced_reproduced.csv", index=False)

    # sanity check: reproduce should match the shipped accounts.csv exactly
    shipped = pd.read_csv("accounts.csv")
    match = (accounts["rebalanced_rep_id"] == shipped["rebalanced_rep_id"]).mean()
    print(f"Reproduction match rate vs. shipped accounts.csv: {match:.1%}")
