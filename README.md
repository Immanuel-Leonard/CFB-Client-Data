# College Football Client Data Pipeline

An end-to-end data pipeline that pulls college football player data from the College Football Data API, transforms it into analytics-ready tables in PostgreSQL (Supabase), and computes a position-adjusted player rating.

**Business question:** Which college football players stand out relative to others at their position, and how can that be expressed as a repeatable, queryable metric?

## Project overview

The pipeline:

1. Pulls roster, player usage, PPA, and per-season statistics for a given season.
2. Maps raw positions into eight position groups.
3. Flattens category-and-statType pairs from the API into wide per-season columns.
4. Computes within-group percentile ranks for PPA and usage.
5. Combines them into a weighted rating stored per player-season.
6. Upserts everything into a Supabase PostgreSQL database in batches.

The rating is a **descriptive, percentile-based heuristic for scouting triage** — not a validated predictive model of future performance.

## Architecture

```
College Football Data API  →  transform in notebook  →  Supabase (Postgres)  →  SQL
      (REST, JSON)              (Python, pandas)          (5 tables)            (queries)
```

## Data sources

Four endpoints from the College Football Data API, all for a single season:

| Endpoint | Used for |
|---|---|
| `/roster` | Player identity: id, name, team, position, class year, height, weight |
| `/ppa/players/season` | Average predicted points added per player |
| `/player/usage` | Overall usage rate and play count |
| `/stats/player/season` | Every category and stat type the player recorded |

A full season pull returned **80,698 player-season stat rows** in the notebook's recorded run, which is why the pipeline aggregates before writing rather than inserting raw rows.

## Schema

Five tables in `public`, documented in `sql/schema.sql`:

| Table | Grain |
|---|---|
| `players` | One row per athlete (career identity) |
| `players_season_stats` | One row per athlete per season (wide production) |
| `player_ratings` | One row per athlete per season (derived rating) |
| `player_social` | One row per athlete (off-field context) |
| `year_2_cb_stats` | One row per athlete per season (denormalised CB scouting view) |

`players_season_stats` and `player_ratings` are keyed on `(athlete_id, season)`; `players` and `player_social` on `athlete_id`, with foreign keys from all three child tables. Row-level security is enabled on every table.

## The rating

For each player, within their position group and season:

```
rating = w_ppa × ppa_percentile + w_usage × usage_percentile
```

Weights vary by group, reflecting how much each position's value shows up in efficiency versus workload:

| Group | Raw positions | Weights |
|---|---|---|
| QB | QB | 0.75 / 0.25 |
| RB | RB, FB | 0.65 / 0.35 |
| WR | WR | 0.65 / 0.35 |
| TE | TE | 0.65 / 0.35 |
| OL | C, RT, LT, RG, LG | 0.50 / 0.50 |
| DL | NT, DE, DT | 0.70 / 0.30 |
| LB | OLB, ILB, MLB | 0.70 / 0.30 |
| DB | CB, SS, FS | 0.70 / 0.30 |

Percentile rank is computed as the share of players in the same group with a value less than or equal to the player's, so the rating is always relative to the group it sits in.

## Setup

Credentials are supplied at runtime and never stored in the notebook. In Google Colab, add these to the Secrets panel with notebook access enabled:

`CFB_API`, `SUPABASE_URL`, `SUPABASE_KEY`

Then run the notebook top to bottom:

```python
%pip install supabase requests pandas
from datasets import load_dataset  # not required; listed for reference only
```

The notebook loads its credentials with `userdata.get(...)`, builds the API headers from the token, and creates a Supabase client. Nothing is hardcoded.

For a local run, use environment variables instead:

```bash
export CFB_API_TOKEN=your_token_here
export SUPABASE_URL=[your-project.supabase.co](https://your-project.supabase.co)
export SUPABASE_KEY=your_service_or_anon_key
```

## Running the pipeline

1. Set `SEASON` to the year you want to load.
2. Run the fetch and transform cells, which build `players_row`, `stats_row`, and `rating_row` in memory.
3. Run the upsert cell, which writes in batches of 500 and deduplicates on the natural key before writing.

Upserts use `on_conflict` so re-running a season updates rather than duplicates rows.

## Querying the data

`sql/queries/` holds analytical SQL. A representative query ranks players within each position group using a CTE and a window function:

```sql
WITH ranked AS (
    SELECT p.first_name, p.last_name, p.team,
           r.season, r.position_group, r.rating,
           DENSE_RANK() OVER (
               PARTITION BY r.season, r.position_group
               ORDER BY r.rating DESC
           ) AS position_rank
    FROM public.players p
    JOIN public.player_ratings r ON p.athlete_id = r.athlete_id
    WHERE r.season = 2026 AND r.rating IS NOT NULL
)
SELECT * FROM ranked WHERE position_rank <= 5
ORDER BY position_group, position_rank;
```

## Known limitations

- **The rating is a heuristic.** It blends two percentile ranks with hand-chosen weights. Those weights were not fitted to any outcome and the score has not been validated against future performance.
- **Percentile ranks are season-relative.** A 0.90 rating in one season is not comparable to a 0.90 in another unless the populations are similar.
- **Small samples distort percentiles.** Players with few plays can rank highly on efficiency. The `plays` column exists so queries can filter on sample size, and most current queries do not use it.
- **No strength-of-schedule adjustment.** Performance against weaker opponents is treated the same as performance against strong ones.
- **`year_2_cb_stats` duplicates data.** It repeats identity and rating columns from the core tables to make one scouting query join-free. That is a deliberate tradeoff, not an accident, and it means the view must be rebuilt when the underlying tables change.
- **`player_social.rating` is text** and is unrelated to `player_ratings.rating`, which is numeric. They are deliberately separate columns; do not join them.
- **Injury data is not loaded.** The `player_injuries` table does not exist, and the notebook's injury upsert is commented out. The `injury_row` list is built and discarded.
- **Single season per run.** Loading a second season requires changing `SEASON` and re-running.

## Planned improvements

- Add a minimum-plays threshold to the rating so small samples do not inflate percentiles.
- Add strength-of-schedule or opponent adjustment.
- Persist multiple seasons and compare rating trajectories.
- Move the transform out of the notebook into `src/` with tests.
- Add data-quality queries for duplicate athlete-seasons, orphaned rows, and ratings outside 0–1.
- Create or remove `player_injuries` so the built `injury_row` data is either used or dropped.
- Rename the category-derived columns to snake_case, or normalise them into a tall `player_stats` table.

## Skills demonstrated

Python, REST API integration, data modelling, position-group mapping, percentile and window calculations, batch upserts, PostgreSQL schema design, environment-based secrets.

