-- The companion window's Account section shows raw token counts, not just dollar cost — cost
-- alone at this scale ("$0.0022") reads as an unhelpfully tiny, opaque number; tokens are the
-- more legible unit for a human glancing at usage. Non-destructive: replaces the view definition
-- only, doesn't touch usage_events or any existing row.
create or replace view public.current_period_usage as
select
  user_id,
  sum(cost_cents) as spent_cents,
  sum(prompt_tokens + completion_tokens) as total_tokens
from public.usage_events
where created_at >= date_trunc('month', now())
group by user_id;
