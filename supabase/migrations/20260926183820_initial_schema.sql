-- Docs/PLANNING.md §59.3 items 2-3: one profile row per Supabase auth user (plan + monthly
-- cap), and a per-request usage ledger the chat-relay Edge Function reads/writes to enforce
-- that cap. Costs are tracked in cents (numeric, not integer) since per-request cost is
-- fractional (a single call can cost a few thousandths of a dollar).

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  plan text not null default 'basic',
  monthly_cap_cents numeric(10, 4) not null default 60, -- Basic tier: $0.60/mo, per the pricing conversation
  created_at timestamptz not null default now()
);

create table public.usage_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  request_kind text not null check (request_kind in ('fast_path', 'agentic')),
  prompt_tokens integer not null,
  completion_tokens integer not null,
  cost_cents numeric(10, 4) not null,
  created_at timestamptz not null default now()
);

create index usage_events_user_id_created_at_idx on public.usage_events (user_id, created_at);

-- Current calendar-month spend per user — the relay's budget pre-check reads this on every
-- request, so it needs to stay cheap; the index above keeps this aggregation fast even as the
-- ledger grows. Calendar-month billing periods are a v1 simplification (Docs/PLANNING.md
-- §59.3 item 3) — doesn't yet align to each account's actual subscription renewal date.
create view public.current_period_usage as
select
  user_id,
  sum(cost_cents) as spent_cents
from public.usage_events
where created_at >= date_trunc('month', now())
group by user_id;

-- RLS: a user can read their own profile/usage for an in-app "usage this month" display later,
-- but never anyone else's. All writes happen via the Edge Function using the service role key,
-- which bypasses RLS entirely — that's intended, not a gap to close.
alter table public.profiles enable row level security;
alter table public.usage_events enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid () = id);

create policy "usage_events_select_own" on public.usage_events
  for select using (auth.uid () = user_id);

-- New Supabase auth user -> auto-create their profile row, so the relay never has to handle
-- "authenticated but no profile yet" as a special case.
create function public.handle_new_user () returns trigger as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
after insert on auth.users for each row
execute procedure public.handle_new_user ();
