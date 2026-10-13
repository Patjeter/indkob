-- v42: notifikationer når der kommer nye varer på listen
-- Kør i Supabase → SQL Editor. Kræver at Edge Function "push" er udrullet (supabase/functions/push).

-- 1) hvem og hvilken telefon tilføjede varen, og om der er sendt besked
alter table public.items add column if not exists added_by text default (auth.jwt()->>'email');
alter table public.items add column if not exists added_dev text;
alter table public.items add column if not exists notified boolean not null default true;   -- eksisterende varer: allerede "sendt"
alter table public.items alter column notified set default false;                            -- nye varer: venter på besked

-- 2) navn der vises i beskeden ("Besnik tilføjede 3 varer")
alter table public.family add column if not exists name text;
update public.family set name = 'Besnik' where name is null and email ilike 'besnik%';

-- 3) telefoner der vil have besked
create table if not exists public.push_subs (
  endpoint   text primary key,
  p256dh     text not null,
  auth       text not null,
  dev        text not null,
  lang       text not null default 'da',
  email      text default (auth.jwt()->>'email'),
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;
drop policy if exists "kun familien" on public.push_subs;
create policy "kun familien" on public.push_subs for all to authenticated
  using (public.is_family()) with check (public.is_family());
revoke all on public.push_subs from anon;
grant select, insert, update, delete on public.push_subs to authenticated;

-- 4) tag varer der er klar til besked: fra en telefon der har været stille i 3 minutter
create or replace function public.push_claim() returns setof public.items
language sql security invoker set search_path = public as $$
  update public.items i set notified = true
  where i.notified = false
    and not exists (
      select 1 from public.items j
      where j.notified = false
        and coalesce(j.added_dev,'') = coalesce(i.added_dev,'')
        and coalesce(j.added_by,'')  = coalesce(i.added_by,'')
        and j.created_at > now() - interval '3 minutes')
  returning i.*;
$$;
revoke all on function public.push_claim() from public, anon, authenticated;
grant execute on function public.push_claim() to service_role;

-- 5) tjek hvert minut; kald kun funktionen når der faktisk er noget at sende
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;   -- ikke i public (Security Advisor)
select cron.unschedule('indkob-push') where exists (select 1 from cron.job where jobname = 'indkob-push');
select cron.schedule('indkob-push', '* * * * *', $c$
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := '{}'::jsonb)
  where exists (select 1 from public.items where notified = false and created_at < now() - interval '3 minutes');
$c$);
