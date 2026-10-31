-- v80: Nødlager – familiens beredskabslager (Mere → Nødlager). v81: holdbarhed og besked, når noget skal bruges.
-- Varerne og mængderne står i appen (NOD i index.html). Her gemmes kun, hvad familien har:
--   uger = 0 mangler · 1 = har til 1 uge · 2 = har til 2 uger (ting uden ugemængde: > 0 = har)
-- Målet (1 eller 2 uger) ligger i familie_indstilling 'nodlager_uger'. Kør i Supabase → SQL Editor.
create table if not exists public.nodlager (
  key        text primary key,
  uger       smallint not null default 0 check (uger between 0 and 2),
  updated_at timestamptz not null default now(),
  updated_by text default (auth.jwt()->>'email')
);
alter table public.nodlager enable row level security;
drop policy if exists "kun familien" on public.nodlager;
create policy "kun familien" on public.nodlager for all to authenticated
  using (public.is_family()) with check (public.is_family());
revoke all on public.nodlager from anon;
grant select, insert, update, delete on public.nodlager to authenticated;

create or replace function public.nodlager_stempel() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'varslet_for' - 'updated_at' - 'updated_by') = (to_jsonb(old) - 'varslet_for' - 'updated_at' - 'updated_by')
  then return new; end if;   -- kun advarslen er sendt: ikke en ændring fra familien
  new.updated_at := now(); new.updated_by := coalesce(auth.jwt()->>'email', new.updated_by); return new;
end $$;
drop trigger if exists nodlager_stempel on public.nodlager;
create trigger nodlager_stempel before update on public.nodlager for each row execute function public.nodlager_stempel();

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'nodlager')
  then alter publication supabase_realtime add table public.nodlager; end if;
end $$;

insert into public.familie_indstilling(key, value) values ('nodlager_uger', '1'::jsonb) on conflict do nothing;

-- v81: holdbarhed. Appen gemmer navnet (dansk/albansk), datoen for det, der udløber først,
-- og hvor mange dage før man vil advares (varsel). nod_varsel() finder det, der skal bruges snart,
-- og sender én besked pr. dato (varslet_for husker datoen, der er advaret om).
alter table public.nodlager add column if not exists navn text;
alter table public.nodlager add column if not exists navn_sq text;
alter table public.nodlager add column if not exists udloeb date;
alter table public.nodlager add column if not exists varsel smallint not null default 30;
alter table public.nodlager add column if not exists varslet_for date;

create or replace function public.nod_varsel() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_da text; v_sq text; v_n int;
begin
  with due as (
    select n.key, regexp_replace(coalesce(n.navn, n.key), '\s*[(–].*$', '') navn, regexp_replace(coalesce(n.navn_sq, n.navn, n.key), '\s*[(–].*$', '') navn_sq, n.udloeb, n.varsel
    from nodlager n
    where n.uger > 0 and n.udloeb is not null
      and n.udloeb <= current_date + n.varsel
      and n.varslet_for is distinct from n.udloeb
    order by n.udloeb, n.key
  ), mark as (
    update nodlager n set varslet_for = n.udloeb from due where n.key = due.key returning n.key
  )
  select count(*),
         string_agg(format('%s (%s)', d.navn, to_char(d.udloeb, 'FMDD/FMMM')), ', ' order by d.udloeb, d.key),
         string_agg(format('%s (%s)', d.navn_sq, to_char(d.udloeb, 'FMDD/FMMM')), ', ' order by d.udloeb, d.key)
    into v_n, v_da, v_sq
  from due d where d.key in (select key from mark);
  if coalesce(v_n, 0) = 0 then return null; end if;
  return jsonb_build_object(
    'da', jsonb_build_object('title', 'Nødlager: brug det snart',
          'body', left(v_da || ' – brug det i hverdagen, og køb nyt til lageret.', 240)),
    'sq', jsonb_build_object('title', 'Rezerva emergjente: përdoreni së shpejti',
          'body', left(v_sq || ' – përdoreni në përditshmëri dhe blini të reja për rezervën.', 240)));
end $$;
revoke all on function public.nod_varsel() from public, anon, authenticated;

-- hver dag kl. 15.10 UTC (16.10 vinter / 17.10 sommer)
select cron.unschedule('indkob-nodlager') where exists (select 1 from cron.job where jobname = 'indkob-nodlager');
select cron.schedule('indkob-nodlager', '10 15 * * *', $c$
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := jsonb_build_object('nod', b))
  from (select public.nod_varsel() as b) x where b is not null;
$c$);
