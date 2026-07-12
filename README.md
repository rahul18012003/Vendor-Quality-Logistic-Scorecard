# Vendor Quality and Logistic Scorecard 

**Identifying which sellers are damaging an e-commerce platform's reputation
through late deliveries and poor reviews — using Python, MySQL, and Power BI.**

![Python](https://img.shields.io/badge/Python-pandas-blue)
![MySQL](https://img.shields.io/badge/MySQL-8.0-orange)
![Power BI](https://img.shields.io/badge/Power%20BI-Dashboard-yellow)

---

## 1. Problem Statement

On a marketplace, the platform's reputation is only as good as its worst
sellers. A customer who receives a late order or has a 1-star experience
blames the *platform*, not the individual seller — hurting retention and
acquisition for the whole business.

This project builds a **seller scorecard** that answers:

- Which sellers deliver late most often, and by how much?
- Which sellers earn the best and worst review scores (with enough order
  volume to be statistically meaningful)?
- Which product categories drive revenue, lateness, and poor ratings?
- Is platform-wide delivery performance improving or degrading over time?
- Which sellers should the platform coach, monitor, or offboard?

**Dataset:** [Olist Brazilian E-commerce (Kaggle)](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
— 5 tables: `orders`, `order_items`, `sellers`, `order_reviews`, `products`
(~100K orders, ~3K sellers, 2016–2018).

---

## 2. Solution Architecture

```
Raw CSVs (Kaggle)
      │
      ▼
Python (pandas) ── data audit → cleaning → feature engineering
      │
      ▼
MySQL 8 ── normalized schema (PK/FK) → flat analysis view (vw_fact_delivery)
      │
      ▼
Power BI ── DAX measures → 2-page interactive dashboard
```

**Design choice worth noting:** all table joins are done in a SQL view
(`vw_fact_delivery`) rather than in Power Query. The BI layer stays thin and
every metric definition lives in one place — the database. *Python did the
filtering, SQL does the joining, Power BI does the presenting.*

---

## 3. What the Code Does (and Why)

### Python — `vendor_scorecard_pipeline.py`

| Step | What | Why |
|---|---|---|
| Data audit | Shape, dtypes, missing values for all 5 tables | Know what needs fixing *before* touching anything |
| Products cleaning | Category nulls → `'Unknown'`; numeric nulls → 0 | Keeps rows usable without breaking numeric dtypes |
| Orders scoping | Keep only `order_status = 'delivered'` | Delivery metrics are meaningless for canceled/processing orders |
| Feature engineering | `delivery_time_days` (purchase → door), `sla_delay_days` (actual − promised) | The two columns that power every dashboard metric |
| Review deduplication | Keep only the **latest** review per order (547 orders had resubmitted reviews) | One customer must never count twice in a seller's rating |
| Referential integrity | Drop order_items/reviews whose parent order was filtered out | Prevents orphan rows and FK failures in MySQL |
| Load to MySQL | Parents before children (sellers/products → orders → items/reviews) | Foreign keys reject child rows without parents |

### MySQL — `vendor_scorecard_analysis.sql`

- **Normalized 5-table schema** with primary keys, a composite key on the
  item-grain fact table, and foreign keys enforcing integrity.
- **`vw_fact_delivery`** — one wide view joining all 5 tables at item grain;
  the single data source for Power BI.
- **Seller scorecard query** — orders fulfilled, avg delivery days, late-rate
  %, avg review score, 1-star rate per seller, with a ≥10-order volume floor.

> 🐛 **Bug caught during development:** the first version of the late-rate
> metric counted late *item rows* against distinct *orders* — a grain
> mismatch that could push a seller's late rate above 100%. Fixed by counting
> `DISTINCT CASE WHEN late THEN order_id END`. Aligning numerator and
> denominator grain is what separates a correct scorecard from a
> plausible-looking wrong one.

### Power BI — DAX highlights

```
Pct Late Deliveries = DIVIDE(
    CALCULATE(DISTINCTCOUNT(fact[order_id]), fact[is_late] = 1),
    [Total Orders])

Vendor Risk Score = ROUND(
    0.6 * ((5 - [Avg Review Score]) / 4 * 100)
  + 0.4 * ([Pct Late Deliveries] * 100), 1)
```

The **Vendor Risk Score** (0–100, higher = worse) blends rating risk (60%)
and lateness risk (40%). Only sellers with **≥10 delivered orders** are
scored, so a seller with 2 orders and one angry review can't top the risk
ranking.

---

## 4. Dashboards

### Page 1 — Vendor Quality and Logistic Scorecard (Executive Overview)
![Executive Overview](images/dashboard_overview.png)

- **KPI row:** 2.97K sellers · 96K orders · $13.22M revenue · 4.08 avg
  review · 7% late deliveries · 16.5 platform risk score.
- **Monthly trend** of review score and late-delivery rate.
- **Top 10 Risk Sellers** — the ranked offboarding/coaching candidates.
- **Risk Quadrant** (avg review × late % × revenue bubble size): bad sellers
  cluster top-left; big bubbles there are urgent.
- **Delivery Status donut:** 93.23% on time vs 6.77% late.
- **Total sales by state map:** revenue concentrated in São Paulo/Southeast.
- Slicers for seller state and product category filter the whole page.

### Page 2 — Seller Scorecard & Category Analysis
![Seller Scorecard](images/dashboard_scorecard.png)

- **Scorecard table:** one row per qualified seller — orders, revenue, avg
  review (blue scale), late %, avg days vs promise, Vendor Risk Score (red
  scale), sorted worst-first.
- **Late Delivery % by category:** portable kitchen appliances, watches &
  gifts, and telephony run ~6–8% late — the problem categories.
- **Revenue by category:** beleza_saude (health & beauty) leads at ~R$1.2M,
  followed by watches/gifts and bed & bath.
- **Avg Review Score by category:** books, CDs/DVDs and kids' fashion earn
  the best ratings (4.4+).

---

## 5. Key Insights

- **96K delivered orders** across **~3,000 sellers** generated **R$13.2M**
  in item revenue (2016–2018). Platform averages: **4.08/5** review score,
  **6.77%** late deliveries, risk score **16.5**.
- The average order arrives **~12 days early** — delivery promises are
  heavily padded. But averages hide the tail: some qualified sellers run
  late on **30–64%** of their orders.
- The worst qualified seller scores **71.8/100**: average review **1.93**
  and **64% late** across 14 orders — a clear offboarding candidate. The
  3rd-worst has **108 orders** at 2.27 avg review: high volume *and* bad
  quality, the most damaging combination.
- **Category patterns:** revenue is led by health & beauty, while lateness
  concentrates in portable appliances and telephony — logistics problems
  are category-shaped, not random.
- Sales are heavily concentrated in **São Paulo**, creating long, late-prone
  shipping lanes to the North/Northeast.

---

## 6. Business Recommendations & Expected Impact

*Assumptions used: average order value ≈ R$138 ($13.22M / 96K orders);
~6,500 late orders per period (6.77% of 96K). Impact figures are directional
estimates to size the opportunity, each tied to a dashboard metric to track.*

| # | Recommendation | Expected impact |
|---|---|---|
| 1 | **Seller probation program** — risk score > 40 with ≥10 orders enters a 60-day improvement window (SLA coaching); no improvement → search demotion or offboarding | Bringing just the Top-10 risk sellers to the platform's 7% baseline removes **~800–1,200 bad experiences/yr ≈ R$110K–165K protected revenue**, plus rating uplift on their ~R$100K+ combined GMV |
| 2 | **Calibrate delivery promises** — orders arrive ~12 days early; tighten quoted dates for reliably fast sellers, keep buffer only for risky ones | Faster quoted delivery lifts conversion; **each +1% conversion ≈ +R$132K GMV/yr** at current volume, with late rate protected by seller-level calibration |
| 3 | **Category-targeted logistics** — portable appliances & telephony run ~6–8% late vs ~5% for the best categories | Halving the gap on the top-3 late categories ≈ **several hundred fewer late orders/yr** in the categories where customers complain most |
| 4 | **1-star review recovery loop** — every 1-star review triggers seller response within 48h; track 1-star rate monthly | Late/1-star experiences churn customers; repeat buyers spend ~2× a one-timer's lifetime value — recovering even 10% of 1-star reviewers retains **hundreds of customers/yr** |
| 5 | **Recruit sellers outside São Paulo** — revenue map shows extreme SP concentration | Regional sellers cut cross-country lanes: **lower delivery days, lower late %, lower freight** simultaneously in the North/Northeast where all three are worst |

---

## 7. Repository Structure

```
├── README.md
├── vendor_scorecard_pipeline.py     # Python: audit → clean → engineer → load
├── vendor_scorecard_analysis.sql    # MySQL: schema + view + scorecard query
├── docs/
│   └── Project_Documentation.pdf    # full write-up
└── images/
    ├── dashboard_overview.png       # Page 1 — executive overview
    └── dashboard_scorecard.png      # Page 2 — scorecard table & categories
```

## 8. How to Reproduce

1. Download the dataset from Kaggle; place the 5 CSVs next to the script.
2. `pip install pandas sqlalchemy pymysql`
3. Create the schema: run the CREATE statements in `vendor_scorecard_analysis.sql`.
4. Run `python vendor_scorecard_pipeline.py` (cleans and loads MySQL).
5. Create `vw_fact_delivery` (same SQL file), then connect Power BI to it.

## 9. Honest Limitations

- Reviews are recorded **per order**, not per seller — an order containing
  items from multiple sellers attributes its single review to each of them.
- Analysis covers delivered orders only; canceled orders are out of scope
  (a good follow-up project on revenue leakage).



