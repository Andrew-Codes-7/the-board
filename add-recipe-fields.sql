-- =============================================================
--  ADD RECIPE FIELDS TO MEALS — run this once in Supabase → SQL Editor.
--
--  The meals table only had (name, link, notes), which left nowhere to put an
--  actual recipe. This adds four columns so a saved meal can hold the real
--  thing — the ingredient list, the steps, how many it serves, and how long it
--  takes — which is what the new "Import a recipe" button fills in.
--
--  ingredients and instructions are plain text with one entry per line. That
--  keeps them readable at a glance in the Supabase table editor, and the app
--  splits them back into a list when it draws the meal card.
--
--  No new tables here, so there is nothing to grant and no new row-level
--  security policies to write — the existing rules on `meals` already cover
--  these columns.
-- =============================================================

alter table meals add column if not exists ingredients  text;
alter table meals add column if not exists instructions text;
alter table meals add column if not exists servings     text;
alter table meals add column if not exists total_time   text;


-- =============================================================
--  DONE. Reload the app. Existing meals are untouched — they just have these
--  four fields empty until you edit them or import a recipe over the top.
-- =============================================================
