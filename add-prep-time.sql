-- =============================================================
--  ADD PREP TIME TO MEALS — run this once in Supabase → SQL Editor.
--
--  One column. Recipe sites publish "prep time" and "total time" separately,
--  and for anything slow-cooked the two are wildly different — the white chicken
--  chili is 5 minutes of prep and 8 hours of sitting there. Showing 8 hours on
--  the card answers the wrong question: what you want to know at 5pm is how much
--  of YOUR time it needs, not how long the crockpot is busy.
--
--  So the card leads with prep time on slow-cooker recipes and moves the long
--  cook time to a badge beside it. Both numbers are kept; only which one gets
--  top billing changes.
--
--  Nothing detects "is this a slow cooker recipe" in the database — that's
--  worked out from the recipe text when the card is drawn, so it also applies
--  to meals you typed in by hand and to everything already saved.
-- =============================================================

alter table meals add column if not exists prep_time text;


-- =============================================================
--  DONE. Reload the app. Existing meals are untouched — re-import one, or type
--  a prep time into the meal editor, to fill this in.
-- =============================================================
