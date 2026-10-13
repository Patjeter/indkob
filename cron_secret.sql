-- Push-funktionen kører kun, når kaldet kommer fra databasens egne planlagte kørsler.
-- En tilfældig hemmelighed ligger i en tabel, som kun databasen og Edge Function (service role) kan læse.
create table if not exists public.cron_secret (
  id     int primary key default 1 check (id = 1),
  secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
alter table public.cron_secret enable row level security;
revoke all on public.cron_secret from anon, authenticated, public;
insert into public.cron_secret (id) values (1) on conflict (id) do nothing;

-- prisalarm_claim returnerer nu også nøglerne, så et fund kan sendes igen, hvis levering fejler
drop function if exists public.prisalarm_claim();
create function public.prisalarm_claim()
returns table (alarm_id uuid, offer_id text, email text, key text, name_da text, name_sq text, max_price numeric,
               store text, heading text, price numeric, eq_price numeric, valid_to date)
language sql security invoker set search_path = public as $$
  with c as (
    update prisalarm_hit h set notified = true
     where not h.notified and h.valid_to >= current_date
    returning h.*)
  select c.alarm_id, c.offer_id, a.email, a.key, a.name_da, a.name_sq, a.max_price, c.store, c.heading, c.price, c.eq_price, c.valid_to
    from c join prisalarm a on a.id = c.alarm_id
   where a.active;
$$;
revoke all on function public.prisalarm_claim() from public, anon, authenticated;
grant execute on function public.prisalarm_claim() to service_role;

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
