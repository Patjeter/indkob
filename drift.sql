-- Synlig automatik (v71): status i appen og besked på telefonen, hvis noget er gået i stå.

-- de 7 kæder og den seneste dag, hver af dem havde tilbud med i hentningen
create or replace function public.drift_kaeder() returns table(store text, hentet date)
language sql stable security invoker set search_path = public as $$
  select v.store, (select max(t.fetched) from tjek_offers t where t.store = v.store)
    from (values ('Lidl'),('Netto'),('REMA 1000'),('føtex'),('MENY'),('365discount'),('SuperBrugsen')) v(store)
$$;
revoke all on function public.drift_kaeder() from public, anon, authenticated;

-- planlagte opgaver, hvis seneste kørsel det sidste døgn fejlede (fx tilbud-vis 14/10)
create or replace function public.drift_fejl() returns setof text
language sql stable security invoker set search_path = public as $$
  select job from (
    select distinct on (j.jobname) j.jobname as job, d.status
      from cron.job_run_details d join cron.job j on j.jobid = d.jobid
     where d.start_time > now() - interval '24 hours'
     order by j.jobname, d.start_time desc) x
   where status = 'failed'
$$;
revoke all on function public.drift_fejl() from public, anon, authenticated;

-- status til appen (Mere → Automatik); kun familien
create or replace function public.status_automatik() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_family() then raise exception 'ingen adgang'; end if;
  return jsonb_build_object(
    'idag',              current_date,
    'kaeder',            (select jsonb_object_agg(store, hentet) from drift_kaeder()),
    'tilbud_vist',       (select max(created_at) from offers where source = 'auto'),
    'tilbud_nu',         (select count(*) from offers where valid_to >= current_date),
    'lidl_priser',       (select max(last_seen) from lidl_products),
    'kvit_seneste_koeb', (select max(dato) from kvit),
    'kvit_indlaest',     (select max(indlaest) from kvit),
    'push_venter',       (select count(*) from push_retry),
    'fejl',              (select coalesce(jsonb_agg(f), '[]'::jsonb) from drift_fejl() f));
end $$;
revoke all on function public.status_automatik() from public, anon;
grant execute on function public.status_automatik() to authenticated;

-- tekst til en advarsel, eller null når alt kører
create or replace function public.drift_tjek() returns text
language sql stable security invoker set search_path = public as $$
  select nullif(concat_ws(' ',
    -- en fejlet kørsel i nat vises kun i appen (Mere → Automatik); beskeden er kun for det, familien selv skal gøre noget ved
    (select 'Ingen tilbud fra ' || string_agg(store, ', ') || ' i 2 dage.'
       from drift_kaeder() where coalesce(hentet, '-infinity') < current_date - 1),
    case when coalesce((select max(last_seen) from lidl_products), '-infinity') < current_date - 2
         then 'Lidls priser er ikke opdateret i 3 dage.' end,
    case when coalesce((select max(indlaest) from kvit), '-infinity') < now() - interval '9 days'
         then 'Ingen nye Lidl-kvitteringer i over en uge. Har I handlet i Lidl, så log ind på lidl.dk og i appen i Chrome på Macen.' end
  ), '')
$$;
revoke all on function public.drift_tjek() from public, anon, authenticated;

-- hver morgen kl. 7.15 (dansk sommertid): besked, hvis noget er gået i stå
select cron.unschedule('indkob-drift') where exists (select 1 from cron.job where jobname = 'indkob-drift');
select cron.schedule('indkob-drift', '15 5 * * *', $c$
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := jsonb_build_object('alert', public.drift_tjek()))
  where public.drift_tjek() is not null;
$c$);
