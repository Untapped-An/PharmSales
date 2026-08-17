# Pharma Sales Territory & Rep Performance Analysis

A commercial-analytics project simulating a pharma sales territory realignment: identifying workload imbalance across a field force, rebalancing account assignments by value, and quantifying the impact on rep workload and effective quota attainment.

**Stack:** Python (Pandas/NumPy) · MySQL · Excel

---
#What This Project Does

Answers four business questions for a pharma sales organization:

How unevenly are accounts currently distributed across reps?
Can territories be rebalanced without disrupting a rep's highest-value relationships?
Does rebalancing actually reduce overload, or just move the problem around?
What's the effect on revenue the field force can realistically capture?

## Problem

Sales territories drift unevenly over time — senior reps accumulate accounts, workload becomes lopsided, and overloaded reps give less attention per account than reps with a manageable load. This project simulates that drift, then re-balances territories using an account-value-aware algorithm, and measures the before/after impact using SQL and a live Excel dashboard.

## Results at a glance

| Metric | Before | After | Change |
|---|---|---|---|
| Workload std. dev. (revenue potential) | $46,105 | $28,419 | **−38.4%** |
| Coefficient of variation | 41% | 25% | −16 pts |
| Effective captured revenue (of total potential) | 82.6% | 93.1% | **+13% uplift** |
| Reps over capacity (>12 accounts) | 19 | 24 | +5 *(see note below)* |
| Total excess load (accounts over capacity, summed) | 112 | 43 | **−62%** |

**Note on the capacity count:** the headcount-over-threshold metric moves the wrong direction after rebalancing. This is expected and explained, not a bug: that metric is blind to magnitude — it scores a rep 1 account over the line the same as a rep 12 over. The *total excess load* metric (which sums how far over, not just who's over) tells the real story: rebalancing traded a few catastrophically overloaded reps for more, but only mildly, overloaded reps — a strict improvement once you account for the fact that the attention-capture penalty is convex (see Methodology).

---

## Project structure

```
├── generate_data.py              # Stage 1: synthetic dataset generation
├── rebalance_algorithm.py        # Stage 2: standalone rebalancing logic
├── accounts.csv                  # Output: 620 accounts, region/revenue/assignments
├── reps.csv                      # Output: 50 reps across 5 regions
├── territory_analysis.sql        # MySQL queries: measurement & analysis
├── Pharma_Territory_Analysis.xlsx# Formula-driven dashboard (3 sheets)
└── README.md
```

## Pipeline

```
generate_data.py  →  accounts.csv, reps.csv  →  rebalance_algorithm.py  →  rebalanced_rep_id
                                                          │
                                                          ▼
                                          territory_analysis.sql  (measures before vs. after)
                                                          │
                                                          ▼
                                    Pharma_Territory_Analysis.xlsx  (dashboard, live formulas)
```

## How to run it

**1. Generate the data**
```bash
pip install pandas numpy
python generate_data.py
```
Produces `accounts.csv` (620 rows) and `reps.csv` (50 rows).

**2. Run the rebalance**
```bash
python rebalance_algorithm.py
```
Reads the CSVs, applies the rebalancing algorithm, and writes `accounts_rebalanced_reproduced.csv`. Prints a match-rate check against the shipped `accounts.csv` (should be 100%).

**3. Run the SQL analysis**
Open MySQL Workbench (or any MySQL 8.0+ client):
- Run the `CREATE TABLE` statements at the top of `territory_analysis.sql`
- Import `accounts.csv` and `reps.csv` into the corresponding tables
- Run each numbered query in order; results are documented inline as SQL comments

**4. Open the dashboard**
Open `Pharma_Territory_Analysis.xlsx`. All KPI tiles and the `Rep_Summary` sheet are formula-driven (`COUNTIFS`/`SUMIFS`/`STDEVP`/`SUMPRODUCT`) off the raw `Accounts` sheet — edit any account's region or revenue and the whole workbook recalculates.

---

## Methodology

### Data generation (`generate_data.py`)
- 620 synthetic accounts across 50 reps in 5 regions (10 reps/region).
- Revenue potential drawn from a **log-normal distribution** (mean=9.0, σ=0.55, clipped to $2,000–$100,000) — chosen because real account/prescriber value is right-skewed: many modest accounts, a few large ones. A normal distribution would produce unrealistic symmetric values.
- The **original** territory assignment is deliberately unbalanced: within each region, the first 40% of reps (simulating tenured reps) receive 1.6x the assignment weight of the rest — modeling realistic legacy drift rather than a contrived worst case.

### Rebalancing (`rebalance_algorithm.py`)
A **targeted rebalance**, not a full from-scratch optimization — this mirrors how an analyst would actually redraw a few territory lines:
1. Within each region, compute the mean and standard deviation of account count per rep.
2. Flag reps more than 0.6 std. dev. above the mean as *overloaded*, and more than 0.6 std. dev. below as *underloaded*.
3. For each overloaded rep, move their **lowest-value accounts first** — not random, not highest-value — to whichever underloaded rep currently carries the fewest accounts, until the overloaded rep reaches the regional mean.

**Why lowest-value-first:** high-value accounts represent established relationships; moving a rep's best account is disruptive and risks revenue loss. Moving the cheapest accounts achieves the same balancing goal at the lowest disruption cost. (Result: 0% of top-half-value accounts were ever reassigned.)

### Effective capture model (used in SQL query 7)
Models attention dilution: a rep can give full attention up to a capacity of **12 accounts** (an asserted modeling parameter — see Limitations). Beyond that, effective capture rate = `capacity / actual_account_count`, capped at 1.0. Summing `revenue_potential × capture_rate` across all accounts, before vs. after rebalancing, gives the effective-quota-attainment uplift.

---
Key Findings
Workload variance across the field force drops 38% after rebalancing, without touching a single top-half-value account
The rebalance is deliberately conservative — it moves each overloaded rep's lowest-value accounts first, protecting established relationships
A simple headcount metric ("reps over capacity") looks worse after rebalancing — but total excess load, the metric that actually reflects revenue risk, falls 62%
Effective, attention-adjusted revenue capture rises from 82.6% to 93.1% of total territory potential

## Known limitations

- **Simulated data, not real-world data.** Distributions were chosen to be realistic but haven't been validated against actual IQVIA-style territory data.
- **Account scale.** ~12 accounts/rep models a key-account or hospital-system structure, not individual HCP-level prescriber coverage (which would realistically run 100–200+ targets/rep).
- **Capacity threshold (12) is asserted, not derived** from call-frequency data, and no sensitivity analysis was run varying it.
- **No geographic modeling.** The rebalance optimizes account count and value only — it does not account for travel time, territory contiguity, or the relationship-disruption cost of reassigning an account away from a rep who has served it for a while.
- **NTILE() in the SQL is descriptive, not decisional.** The `NTILE(4)` window function in query 5 reports value quartiles for client-facing segmentation; it is not what drives the rebalance logic itself, which uses a direct value-sort in `rebalance_algorithm.py`.
- **Minor schema redundancy.** `region` is stored on both `accounts` and implicitly via `reps`, which is a small denormalization (not enforced via a strict 3NF design).

## Possible next steps

- Validate distributional assumptions against real anonymized territory data.
- Add a travel-time/contiguity constraint to the rebalancing algorithm.
- Run a sensitivity analysis on the capacity threshold.
- Extend the capture-rate model to a smoother (non-linear) response curve instead of a hard capacity cutoff.