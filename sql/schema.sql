-- =============================================================================
-- College Football Client Data — database schema
-- =============================================================================
-- Project:   Punt & Rally data (Supabase, Postgres 17)
-- Purpose:   Stores college football player rosters, per-season production,
--            a percentile-based player rating, and social/injury context.
--
-- This file documents the schema only. It contains no connection strings,
-- hostnames, credentials, or player records.
--
-- Grain of each table, one line each:
--   players               one row per athlete (career-level identity)
--   players_season_stats  one row per athlete per season (production)
--   player_ratings        one row per athlete per season (derived score)
--   player_social         one row per athlete (off-field context)
--   year_2_cb_stats       one row per athlete per season (CB scouting view)
--
-- Reconstructed from the live database. The source pipeline is
-- CFB_Client_Data.ipynb, which loads data from the College Football Data API
-- and upserts it here through the Supabase client.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- players
-- Career-level athlete identity, keyed on the API's athlete id.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.players (
    athlete_id  bigint      PRIMARY KEY,
    first_name  text,
    last_name   text,
    team        text,
    position    text,
    class_year  text,
    height      varchar,
    weight      text,
    feet        integer,
    inches      integer,
    update_at   timestamp   DEFAULT now()
);

COMMENT ON TABLE  public.players            IS 'One row per athlete. Career-level identity, sourced from the CFB API roster endpoint.';
COMMENT ON COLUMN public.players.athlete_id IS 'Primary key. CFB API athlete id.';
COMMENT ON COLUMN public.players.position   IS 'Raw position as reported by the API (e.g. CB, OLB, RT). Mapped to position_group in player_ratings.';
COMMENT ON COLUMN public.players.class_year IS 'Eligibility year. Stored as text because the source feed is not strictly numeric.';
COMMENT ON COLUMN public.players.feet       IS 'Parsed from height. Kept alongside the raw height string for filtering.';
COMMENT ON COLUMN public.players.inches     IS 'Parsed from height. Kept alongside the raw height string for filtering.';


-- -----------------------------------------------------------------------------
-- players_season_stats
-- Per-season production. Column naming follows the API's
-- category_statType convention, flattened into one wide row per athlete-season.
-- Nullable throughout, because a player only has values for the categories
-- their position actually produces.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.players_season_stats (
    athlete_id          bigint  NOT NULL,
    season              integer NOT NULL,

    -- Efficiency and workload
    avg_ppa_overall     numeric,
    avg_ppa_pass        numeric,
    avg_ppa_rush        numeric,
    avg_ppa_rec         numeric,
    usage_pct           numeric,
    plays               integer,

    -- Defensive
    defensive_PD        numeric,
    defensive_QB_HUR    numeric,
    defensive_SACKS     numeric,
    defensive_SOLO      numeric,
    defensive_TD        numeric,
    defensive_TFL       numeric,
    defensive_TOT       numeric,

    -- Fumbles
    fumbles_FUM         numeric,
    fumbles_LOST        numeric,
    fumbles_REC         numeric,

    -- Interceptions
    interceptions_AVG   numeric,
    interceptions_INT   numeric,
    interceptions_TD    numeric,
    interceptions_YDS   numeric,

    -- Kick returns
    kickReturns_AVG     numeric,
    kickReturns_LONG    numeric,
    kickReturns_NO      numeric,
    kickReturns_TD      numeric,
    kickReturns_YDS     numeric,

    -- Kicking
    kicking_FGA         numeric,
    kicking_FGM         numeric,
    kicking_LONG        numeric,
    kicking_PCT         numeric,
    kicking_PTS         numeric,
    kicking_XPA         numeric,
    kicking_XPM         numeric,

    -- Passing
    passing_ATT         numeric,
    passing_COMPLETIONS numeric,
    passing_INT         numeric,
    passing_PCT         numeric,
    passing_TD          numeric,
    passing_YDS         numeric,
    passing_YPA         numeric,

    -- Punt returns
    puntReturns_AVG     numeric,
    puntReturns_LONG    numeric,
    puntReturns_NO      numeric,
    puntReturns_TD      numeric,
    puntReturns_YDS     numeric,

    -- Punting
    punting_In_20       numeric,
    punting_LONG        numeric,
    punting_NO          numeric,
    punting_TB          numeric,
    punting_YDS         numeric,
    punting_YPP         numeric,

    -- Receiving
    receiving_LONG      numeric,
    receiving_REC       numeric,
    receiving_TD        numeric,
    receiving_YDS       numeric,
    receiving_YPR       numeric,

    -- Rushing
    rushing_CAR         numeric,
    rushing_LONG        numeric,
    rushing_TD          numeric,
    rushing_YDS         numeric,
    rushing_YPC         numeric,

    CONSTRAINT players_season_stats_pkey
        PRIMARY KEY (athlete_id, season),
    CONSTRAINT players_season_stats_athlete_id_fkey
        FOREIGN KEY (athlete_id) REFERENCES public.players (athlete_id)
);

COMMENT ON TABLE  public.players_season_stats                 IS 'One row per athlete per season. Wide column set mirroring the CFB API category_statType structure.';
COMMENT ON COLUMN public.players_season_stats.season          IS 'Season year as reported by the API (e.g. 2026).';
COMMENT ON COLUMN public.players_season_stats.avg_ppa_overall IS 'Average predicted points added, all play types. Feeds ppa_percentile in player_ratings.';
COMMENT ON COLUMN public.players_season_stats.usage_pct       IS 'Share of team plays the athlete was involved in. Feeds usage_percentile in player_ratings.';
COMMENT ON COLUMN public.players_season_stats.plays           IS 'Play count behind usage_pct. Kept for sample-size filtering.';


-- -----------------------------------------------------------------------------
-- player_ratings
-- Derived score. Computed in CFB_Client_Data.ipynb as a weighted blend of
-- within-position-group percentile ranks, then upserted here.
--   rating = w_ppa * ppa_percentile + w_usage * usage_percentile
-- Weights vary by group (e.g. QB 0.75/0.25; OL 0.5/0.5).
-- This is a descriptive heuristic, not a validated predictive model.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.player_ratings (
    athlete_id       bigint  NOT NULL,
    season           integer NOT NULL,
    position_group   text,
    ppa_percentile   numeric,
    usage_percentile numeric,
    rating           numeric,
    computed_at      timestamptz DEFAULT now(),

    CONSTRAINT player_ratings_pkey
        PRIMARY KEY (athlete_id, season),
    CONSTRAINT player_ratings_athlete_id_fkey
        FOREIGN KEY (athlete_id) REFERENCES public.players (athlete_id)
);

COMMENT ON TABLE  public.player_ratings                  IS 'One row per athlete per season. Derived rating, recomputed on each pipeline run.';
COMMENT ON COLUMN public.player_ratings.position_group   IS 'Grouped position (QB, RB, WR, TE, OL, DL, LB, DB). Raw positions are mapped in the notebook.';
COMMENT ON COLUMN public.player_ratings.ppa_percentile   IS 'Percentile rank of avg_ppa_overall within the same position group and season. Range 0-1.';
COMMENT ON COLUMN public.player_ratings.usage_percentile IS 'Percentile rank of usage_pct within the same position group and season. Range 0-1.';
COMMENT ON COLUMN public.player_ratings.rating           IS 'Weighted blend of the two percentiles. Range 0-1. Heuristic scouting signal, not a projection.';


-- -----------------------------------------------------------------------------
-- player_social
-- Off-field context, joined back to players on athlete_id.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.player_social (
    athlete_id  bigint PRIMARY KEY,
    instagram   text,
    rating      text,

    CONSTRAINT player_social_athlete_id_fkey
        FOREIGN KEY (athlete_id) REFERENCES public.players (athlete_id)
);

COMMENT ON TABLE  public.player_social           IS 'One row per athlete. Off-field context used alongside on-field rating.';
COMMENT ON COLUMN public.player_social.rating    IS 'Text, not numeric. Deliberately separate from player_ratings.rating to avoid mixing the two scales.';


-- -----------------------------------------------------------------------------
-- year_2_cb_stats
-- Denormalised scouting view: second-year cornerbacks with defensive production
-- and their computed rating in a single wide row, so the scouting query needs
-- no join. Derived from players, players_season_stats and player_ratings.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.year_2_cb_stats (
    athlete_id       bigint  NOT NULL,
    season           integer NOT NULL,

    -- Identity, denormalised for convenience
    first_name       text,
    last_name        text,
    team             text,
    position         text,
    class_year       text,

    -- Defensive production
    defensive_PD     numeric,
    defensive_QB_HUR numeric,
    defensive_SACKS  numeric,
    defensive_SOLO   numeric,
    defensive_TD     numeric,
    defensive_TFL    numeric,
    defensive_TOT    numeric,

    -- Interceptions
    interceptions_INT numeric,
    interceptions_TD  numeric,
    interceptions_YDS numeric,

    -- Rating, denormalised
    position_group   text,
    ppa_percentile   numeric,
    usage_percentile numeric,
    rating           numeric,

    CONSTRAINT year_2_cb_stats_pkey PRIMARY KEY (athlete_id, season)
);

COMMENT ON TABLE  public.year_2_cb_stats IS 'One row per athlete per season, filtered to second-year cornerbacks. Denormalised scouting view built from the three core tables.';


-- =============================================================================
-- Column naming note
-- =============================================================================
-- Category-derived columns keep the API's mixed casing (defensive_PD,
-- kickReturns_AVG, punting_In_20) because they are written programmatically
-- from the API response keys. Postgres folds unquoted identifiers to lower
-- case, so reference them unquoted and they resolve correctly.
--
-- A future refactor might normalise these to snake_case, or better, move the
-- category/statType pairs into a tall player_stats table. The wide shape was
-- chosen first for direct Supabase upserts and simple SELECTs.
