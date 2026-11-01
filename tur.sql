-- v78: Næste tur i Kastrup.
--  1) jeres butikker (familie_indstilling 'butikker'): tilbud og turforslag kun fra dem
--  2) seneste pris pr. vare fra kvitteringerne (pakningen I faktisk købte), så listen ikke viser et gennemsnit
--  3) besked på telefonen, når det er værd at handle i dag (tilvalg pr. telefon: push_subs.tur)
-- v82: turbeskeden nævner også gode tilbud til nødlageret (kræver nodlager.sql).
-- Kør i Supabase → SQL Editor. Kræver schema.sql, push.sql, cron_secret.sql, tilbud_auto.sql, lidl_priser.sql, kvit.sql.

-- 1) familiens indstillinger
create table if not exists public.familie_indstilling (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by text default (auth.jwt()->>'email')
);
alter table public.familie_indstilling enable row level security;
drop policy if exists "kun familien" on public.familie_indstilling;
create policy "kun familien" on public.familie_indstilling for all to authenticated
  using (public.is_family()) with check (public.is_family());
revoke all on public.familie_indstilling from anon;
grant select, insert, update, delete on public.familie_indstilling to authenticated;
-- Besniks butikker (31/10): alle 7 kæder; Let-Køb står med, men appen henter ikke tilbud derfra
insert into public.familie_indstilling (key, value) values
  ('butikker', '["Lidl","Netto","365discount","REMA 1000","føtex","MENY","SuperBrugsen"]'::jsonb),
  ('butik_adresser', '[{"kaede": "Lidl", "adresse": "Amager Landevej 42, Tårnby"}, {"kaede": "Lidl", "adresse": "Amager Landevej 244, Tårnby"}, {"kaede": "Netto", "adresse": "Amager Landevej 30–32, Tårnby"}, {"kaede": "Netto", "adresse": "Kastrupgård, Kastrupvej 326"}, {"kaede": "365discount", "adresse": "Kastrupvej 223, Kastrup"}, {"kaede": "365discount", "adresse": "Løjtegårdsvej, Amager Landevej 196"}, {"kaede": "REMA 1000", "adresse": "Willumsvej 2, København S"}, {"kaede": "føtex", "adresse": "Amagerbrogade 290"}, {"kaede": "SuperBrugsen", "adresse": "Amagerbrogade 266"}, {"kaede": "MENY", "adresse": "Tårnbyvej 51, Tårnby"}, {"kaede": "Let-Køb", "adresse": "Skottegården 4, Kastrup"}]'::jsonb)
on conflict (key) do nothing;   -- familiens egne valg i appen overskrives ikke
insert into public.familie_indstilling (key, value) values ('maal', '{"pr_maaned": 5050, "snit": 5558, "spar": 500}'::jsonb) on conflict (key) do nothing;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'familie_indstilling')
  then alter publication supabase_realtime add table public.familie_indstilling; end if;
end $$;

-- 2) seneste pris pr. vare (de sidste 120 dage), med pakningens navn fra kvitteringen
create or replace view public.seneste_pris with (security_invoker = true) as
  select distinct on (l.key) l.key, l.navn, round(l.beloeb / nullif(l.antal, 0), 2) as pris, k.dato::date as dato
    from public.kvit_linjer l join public.kvit k using (tid)
   where l.key is not null and l.key <> '-' and l.antal > 0 and l.antal = round(l.antal)
     and k.dato > now() - interval '120 days'
   order by l.key, k.dato desc, l.nr;
revoke all on public.seneste_pris from anon;
grant select on public.seneste_pris to authenticated;

-- 3) besked om en god tur
alter table public.push_subs add column if not exists tur boolean not null default false;

-- hvad kan spares i dag i jeres butikker på det, I skal bruge: varerne på listen + det, der efter købsrytmen
-- slipper op inden for 3 dage. Besparelsen = tilbuddets førpris for jeres pakning minus tilbudsprisen.
create or replace function public.tur_forslag() returns table(store text, n int, spar numeric, top text)
language sql stable security invoker set search_path = public as $$
  with st as (select jsonb_array_elements_text(value) as store from familie_indstilling where key = 'butikker'),
  need as (
    select i.key from items i where not i.checked and i.key is not null
    union
    select c.key from catalog c
     where (c.data->>'every') is not null and coalesce((c.data->>'n')::int, 0) >= 4
       and (c.data->>'last') is not null
       and (c.data->>'last')::date + (c.data->>'every')::int <= current_date + 3
  ),
  o as (
    select distinct on (o.key, o.store) o.key, o.store, o.title, o.price,
           coalesce(o.ref_price, a.normal_fam, (c.data->>'price')::numeric) as ref
      from offers o
      join need using (key)
      left join lidl_alt a on a.key = o.key
      left join catalog c on c.key = o.key
     where o.source in ('auto', 'valg') and o.valid_to >= current_date
       and coalesce(o.valid_from, current_date) <= current_date
       and o.store in (select store from st)
     order by o.key, o.store, o.price
  ),
  s as (select store, key, title, price, round(ref - price, 2) as spar from o where ref > price)
  select store, count(*)::int, sum(spar),
         (array_agg(title || ' ' || replace(to_char(price, 'FM9990.00'), '.', ',') || ' kr.' order by spar desc))[1]
    from s group by store
   order by sum(spar) desc
$$;
revoke all on function public.tur_forslag() from public, anon;
grant execute on function public.tur_forslag() to authenticated;

-- v79: LAGERPRIS – holdbare varer, I køber tit, på tilbud mindst lige så billigt (relativt) som det bedste, I selv har betalt det sidste år
create or replace function public.lager_forslag() returns table(key text, da text, store text, title text, price numeric, pct int)
language sql stable security invoker set search_path = public as $$
  with st as (select jsonb_array_elements_text(value) as store from familie_indstilling where key = 'butikker'),
  h as (
    select l.key, l.beloeb / l.antal as up
      from kvit_linjer l join kvit k using (tid) join catalog c on c.key = l.key
     where k.dato > now() - interval '12 months' and l.antal > 0 and l.antal = round(l.antal)
       and ((c.data->>'cat') in ('ko','rh','fr')
            or l.key in ('kaffe','te','ris','pasta','olie','hvedemel','sukker','honning','toiletpapir','koekkenrulle','affaldsposer','vaskemiddel','opvask','saft'))
  ),
  hist as (select key, count(*) n, min(up) lav, percentile_cont(0.5) within group (order by up) med from h group by key having count(*) >= 4),
  o as (
    select distinct on (o.key) o.key, o.store, o.title, o.price, 1 - o.price / o.ref_price as rab
      from offers o join hist using (key)
     where o.source in ('auto','valg') and o.ref_price > 0 and o.valid_to >= current_date
       and coalesce(o.valid_from, current_date) <= current_date and o.store in (select store from st)
     order by o.key, o.price / o.ref_price
  )
  select o.key, c.data->>'da', o.store, o.title, o.price, round(o.rab * 100)::int
    from o join hist using (key) join catalog c on c.key = o.key
   where o.rab >= 0.15 and o.rab >= 1 - hist.lav / nullif(hist.med, 0) - 0.02
   order by o.rab desc
$$;
revoke all on function public.lager_forslag() from public, anon;
grant execute on function public.lager_forslag() to authenticated;

-- v79: RET – den af jeres retter, der har flest ingredienser på tilbud i jeres butikker i dag
create or replace function public.ret_forslag() returns table(navn text, paa_tilbud int, ingredienser text)
language sql stable security invoker set search_path = public as $$
  with st as (select jsonb_array_elements_text(value) as store from familie_indstilling where key = 'butikker'),
  ok as (select distinct o.key from offers o
          where o.source in ('auto','valg') and o.valid_to >= current_date and coalesce(o.valid_from, current_date) <= current_date
            and o.store in (select store from st) and coalesce(o.ref_price, 0) > o.price)
  select d.name_da, count(*)::int, string_agg(coalesce(c.data->>'da', i->>'key'), ', ')
    from dishes d cross join jsonb_array_elements(d.items) i
    join ok on ok.key = i->>'key' left join catalog c on c.key = i->>'key'
   where coalesce(d.kind, 'ret') = 'ret'
   group by d.id, d.name_da order by count(*) desc, d.name_da limit 1
$$;
revoke all on function public.ret_forslag() from public, anon;
grant execute on function public.ret_forslag() to authenticated;

-- v79: FORBRUG pr. måned og kategori (til Mere → Forbrug) og status mod målet
create or replace view public.forbrug_kat with (security_invoker = true) as
  select to_char(k.dato at time zone 'Europe/Copenhagen', 'YYYY-MM') as maaned, coalesce(c.data->>'cat', '?') as cat, round(sum(l.beloeb)) as kr
    from kvit_linjer l join kvit k using (tid) left join catalog c on c.key = l.key
   where coalesce(l.key, '') <> '-' and k.dato > now() - interval '7 months'
   group by 1, 2;
revoke all on public.forbrug_kat from anon;
grant select on public.forbrug_kat to authenticated;

create or replace function public.maal_status() returns jsonb
language sql stable security invoker set search_path = public as $$
  with m as (select (value->>'pr_maaned')::numeric maal from familie_indstilling where key = 'maal'),
  b as (select coalesce(sum(coalesce(total, parsed_total)), 0) brugt, count(*) n from kvit
         where dato >= date_trunc('month', now() at time zone 'Europe/Copenhagen'))
  select jsonb_build_object('maaned', to_char(now() at time zone 'Europe/Copenhagen', 'YYYY-MM'),
    'brugt', round(b.brugt), 'kvitteringer', b.n, 'maal', m.maal,
    'dag', extract(day from now() at time zone 'Europe/Copenhagen')::int,
    'dage_i_maaneden', extract(day from (date_trunc('month', now() at time zone 'Europe/Copenhagen') + interval '1 month - 1 day'))::int,
    'prognose', round(b.brugt / greatest(extract(day from now() at time zone 'Europe/Copenhagen'), 1)
                      * extract(day from (date_trunc('month', now() at time zone 'Europe/Copenhagen') + interval '1 month - 1 day'))))
  from m, b
$$;
revoke all on function public.maal_status() from public, anon;
grant execute on function public.maal_status() to authenticated;

create table if not exists public.tur_sendt (dato date primary key, tekst text not null);
alter table public.tur_sendt enable row level security;
revoke all on public.tur_sendt from anon, authenticated;

-- teksten til beskeden, eller null når det ikke er turen værd (mindst 40 kr. i én butik).
-- Samme forslag som i går sendes ikke igen.
create or replace function public.tur_besked() returns jsonb
language plpgsql volatile security invoker set search_path = public as $$
declare b record; l record; r record; nt record; v_tekst text; v_trip boolean;
begin
  select * into b from tur_forslag() limit 1;
  v_trip := found and b.spar >= 40;
  select * into l from lager_forslag() limit 1;
  select * into nt from nod_tilbud();                          -- v82: gode tilbud til nødlageret (nodlager.sql)
  if not v_trip and l is null and nt.tekst is null then return null; end if;        -- intet værd at tage ud for
  if v_trip then
    v_tekst := format('%s sparer %s kr. på %s %s, fx %s', b.store, round(b.spar), b.n,
                      case when b.n = 1 then 'vare' else 'varer' end, b.top);
  end if;
  if l.key is not null then
    v_tekst := concat_ws(' ', v_tekst, format('Lagerpris: %s %s kr. i %s (−%s %%) – køb til et par måneder.',
                         l.title, replace(to_char(l.price, 'FM9990.00'), '.', ','), l.store, l.pct));
  end if;
  select * into r from ret_forslag();
  if found and r.paa_tilbud >= 2 then
    v_tekst := concat_ws(' ', v_tekst, format('Ret: %s (%s på tilbud).', r.navn, r.ingredienser));
  end if;
  v_tekst := concat_ws(' ', v_tekst, nt.tekst);
  v_tekst := left(v_tekst, 240);
  if exists (select 1 from tur_sendt t where t.dato = current_date - 1 and t.tekst = v_tekst)
     or exists (select 1 from tur_sendt t where t.dato = current_date) then return null; end if;
  insert into tur_sendt (dato, tekst) values (current_date, v_tekst);
  insert into nod_tilbud_sendt (offer_id) select unnest(nt.ids) on conflict do nothing;
  delete from nod_tilbud_sendt s where s.sendt < current_date - 60;
  delete from tur_sendt t where t.dato < current_date - 30;
  return jsonb_build_object('title', 'Værd at handle i dag', 'body', v_tekst);
end $$;
revoke all on function public.tur_besked() from public, anon, authenticated;

-- hverdage kl. 13.30 UTC (14.30 vinter / 15.30 sommer): før man tager hjem fra arbejde
select cron.unschedule('indkob-tur') where exists (select 1 from cron.job where jobname = 'indkob-tur');
select cron.schedule('indkob-tur', '30 13 * * 1-5', $c$
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := jsonb_build_object('tur', b))
  from (select public.tur_besked() as b) x where b is not null;
$c$);
