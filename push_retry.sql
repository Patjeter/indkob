-- Genforsøg pr. telefon: fejler en levering midlertidigt, gemmes netop den besked til netop den telefon
-- og sendes igen med stigende ventetid (1, 2, 4, 8, 16 min.). Kun Edge Function (service role) bruger tabellen.
create table if not exists public.push_retry (
  id       bigint generated always as identity primary key,
  endpoint text not null references public.push_subs(endpoint) on delete cascade,
  payload  jsonb not null,
  tries    int not null default 1,
  next_at  timestamptz not null default now() + interval '1 minute'
);
alter table public.push_retry enable row level security;
revoke all on public.push_retry from anon, authenticated, public;

-- kald også funktionen, når der er genforsøg, der venter
select cron.unschedule('indkob-push') where exists (select 1 from cron.job where jobname = 'indkob-push');
select cron.schedule('indkob-push', '* * * * *', $c$
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := '{}'::jsonb)
  where exists (select 1 from public.items where notified = false and created_at < now() - interval '3 minutes')
     or exists (select 1 from public.push_retry where next_at <= now());
$c$);
