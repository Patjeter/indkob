-- Prisalarm: besked på telefonen, når en vare kommer på tilbud under jeres egen grænse.
-- Kør i Supabase → SQL Editor. Bruger Edge Function "push" (supabase/functions/push) og tilbudsautomatikken (tilbud_auto.sql).
-- Prisen sammenlignes for jeres sædvanlige pakkestørrelse (pris pr. kg/l/stk × den mængde I plejer at købe).

create table if not exists public.prisalarm (
  id         uuid primary key default gen_random_uuid(),
  key        text not null,
  name_da    text,
  name_sq    text,
  max_price  numeric not null check (max_price > 0 and max_price < 10000),
  email      text default (auth.jwt()->>'email'),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (key, email)
);
alter table public.prisalarm enable row level security;
revoke all on public.prisalarm from anon, public;
grant select, insert, update, delete on public.prisalarm to authenticated;
drop policy if exists "kun familien" on public.prisalarm;
create policy "kun familien" on public.prisalarm for all to authenticated using (public.is_family()) with check (public.is_family());

create table if not exists public.prisalarm_hit (
  alarm_id   uuid not null references public.prisalarm(id) on delete cascade,
  offer_id   text not null,
  store      text not null,
  heading    text,
  price      numeric not null,
  eq_price   numeric not null,
  valid_from date,
  valid_to   date not null,
  notified   boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (alarm_id, offer_id)
);
alter table public.prisalarm_hit enable row level security;
revoke all on public.prisalarm_hit from anon, public;
grant select on public.prisalarm_hit to authenticated;
drop policy if exists "kun familien" on public.prisalarm_hit;
create policy "kun familien" on public.prisalarm_hit for select to authenticated using (public.is_family());

-- find tilbud under grænsen. Kaldes af cron hver morgen og af appen lige efter en ny alarm.
-- Returnerer antal nye fund og hvilke alarmer der gælder varer, automatikken ikke holder øje med endnu.
create or replace function public.prisalarm_scan() returns jsonb
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(auth.role(), '') in ('authenticated', 'anon') and not public.is_family() then
    raise exception 'ingen adgang';
  end if;
  insert into prisalarm_hit (alarm_id, offer_id, store, heading, price, eq_price, valid_from, valid_to)
  select a.id, t.offer_id, t.store, t.heading, t.price,
         round(coalesce(t.offer_unit * w.ref_qty, t.price), 2), t.valid_from, t.valid_to
    from prisalarm a
    join offer_test t on t.key = a.key
    join watch w on w.key = a.key
   where a.active and t.valid_to >= current_date
     -- samme vare, rigtig enhed og størrelse, ingen svinekød: kandidater og dem der kun er "ikke billigere nok"
     and (t.status in ('kandidat', 'valgt') or t.reason in ('ikke billigere', 'under 1,50 kr. sparet'))
     and round(coalesce(t.offer_unit * w.ref_qty, t.price), 2) <= a.max_price
  on conflict do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('nye', n,
    'uden_overvaagning', coalesce((select jsonb_agg(a.key) from prisalarm a
                                    where a.active and not exists (select 1 from watch w where w.key = a.key and w.active)), '[]'::jsonb));
end $$;
revoke all on function public.prisalarm_scan() from public, anon;
grant execute on function public.prisalarm_scan() to authenticated, service_role;

-- tag fund til besked (kun Edge Function "push")
create or replace function public.prisalarm_claim()
returns table (email text, key text, name_da text, name_sq text, max_price numeric,
               store text, heading text, price numeric, eq_price numeric, valid_to date)
language sql security invoker set search_path = public as $$
  with c as (
    update prisalarm_hit h set notified = true
     where not h.notified and h.valid_to >= current_date
    returning h.*)
  select a.email, a.key, a.name_da, a.name_sq, a.max_price, c.store, c.heading, c.price, c.eq_price, c.valid_to
    from c join prisalarm a on a.id = c.alarm_id
   where a.active;
$$;
revoke all on function public.prisalarm_claim() from public, anon, authenticated;
grant execute on function public.prisalarm_claim() to service_role;

-- hver morgen kl. 6.45 (dansk sommertid) efter tilbudsautomatikken: find fund og send besked
select cron.unschedule('indkob-prisalarm') where exists (select 1 from cron.job where jobname = 'indkob-prisalarm');
select cron.schedule('indkob-prisalarm', '45 4 * * *', $c$
  select public.prisalarm_scan();
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := '{"alarm":true}'::jsonb)
  where exists (select 1 from public.prisalarm_hit where not notified and valid_to >= current_date);
$c$);
