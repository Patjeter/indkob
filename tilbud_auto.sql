-- v46 (TEST): automatisk tilbudsmatch i databasen – alle 7 kæder, mod familiens ~200 faste varer.
-- Skriver kun til testtabellen offer_test; appens offers-tabel røres IKKE før testen er godkendt.
-- Overvågningslisten (watch) indlæses separat (den indeholder familiens egne priser og ligger ikke i repoet).

-- 1) Rå tilbud fra Tjek (alle kæder, hentet avis for avis så føtex' loft på 1000 ikke rammer)
create table if not exists public.tjek_offers (
  id          text primary key,
  store       text not null,
  catalog_id  text,
  catalog     text,
  heading     text not null,
  description text,
  price       numeric not null,
  pre_price   numeric,
  size_from   numeric,
  size_to     numeric,
  unit        text,
  qty_si      numeric,
  si_unit     text,
  valid_from  date,
  valid_to    date,
  fetched     date not null default current_date
);
create index if not exists tjek_offers_valid on public.tjek_offers(valid_to);
create table if not exists public.tjek_jobs (
  req_id bigint primary key, kind text not null, store text not null, catalog_id text, catalog text,
  created_at timestamptz not null default now()
);
-- 2) Overvågningsliste og testresultat
create table if not exists public.watch (
  key text primary key, name text not null, cat text, n int,
  inc text not null, exc text, req text,
  ref_price numeric, ref_qty numeric, ref_si text, usual int not null default 1,
  active boolean not null default true
);
alter table public.watch add column if not exists usual int not null default 1;
create table if not exists public.offer_test (
  key text, name text, offer_id text, store text, heading text, price numeric, pre_price numeric,
  size text, offer_unit numeric, ref_unit numeric, saving numeric, valid_from date, valid_to date,
  status text, reason text, run_at timestamptz not null default now()
);
alter table public.tjek_offers enable row level security;
alter table public.tjek_jobs   enable row level security;
alter table public.watch       enable row level security;
alter table public.offer_test  enable row level security;
revoke all on public.tjek_offers, public.tjek_jobs, public.watch, public.offer_test from anon, authenticated;

-- 3) Hent: trin 1 kataloger pr. kæde, trin 2 tilbud pr. katalog, trin 3 gem
create or replace function public.tjek_fetch_catalogs() returns int
language plpgsql security invoker set search_path = public, extensions as $$
declare d record; n int := 0;
begin
  delete from tjek_jobs where created_at < now() - interval '1 day';
  for d in select * from (values ('Lidl','71c90'),('Netto','9ba51'),('REMA 1000','11deC'),('føtex','bdf5A'),
                                 ('MENY','267e1m'),('365discount','DWZE1w'),('SuperBrugsen','0b1e8')) v(store, id) loop
    insert into tjek_jobs(req_id, kind, store) values (net.http_get(
      url := format('https://squid-api.tjek.com/v2/catalogs?dealer_ids=%s&r_lat=55.6337&r_lng=12.6360&r_radius=10000&limit=50', d.id),
      timeout_milliseconds := 30000), 'cat', d.store);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.tjek_fetch_offers() returns int
language plpgsql security invoker set search_path = public, extensions as $$
declare c record; off int; n int := 0;
begin
  for c in
    select j.store, x->>'id' as cid, x->>'label' as label, (x->>'offer_count')::int as cnt
      from tjek_jobs j join net._http_response r on r.id = j.req_id,
           jsonb_array_elements(case when r.status_code = 200 and left(r.content,1) = '[' then r.content::jsonb else '[]'::jsonb end) x
     where j.kind = 'cat' and (x->>'offer_count')::int > 0 and (x->>'run_till')::timestamptz >= now()
  loop
    for off in 0..least(c.cnt - 1, 900) by 100 loop
      insert into tjek_jobs(req_id, kind, store, catalog_id, catalog) values (net.http_get(
        url := format('https://squid-api.tjek.com/v2/offers?catalog_ids=%s&limit=100&offset=%s', c.cid, off),
        timeout_milliseconds := 30000), 'off', c.store, c.cid, c.label);
      n := n + 1;
    end loop;
  end loop;
  delete from tjek_jobs j using net._http_response r where r.id = j.req_id and j.kind = 'cat';
  return n;
end $$;

create or replace function public.tjek_process() returns jsonb
language plpgsql security invoker set search_path = public, extensions as $$
declare n int; venter int;
begin
  select count(*) into venter from tjek_jobs j left join net._http_response r on r.id = j.req_id where j.kind = 'off' and r.id is null;
  with o as (
    select j.store, j.catalog_id, j.catalog, e
      from tjek_jobs j join net._http_response r on r.id = j.req_id,
           jsonb_array_elements(case when r.status_code = 200 and left(r.content,1) = '[' then r.content::jsonb else '[]'::jsonb end) e
     where j.kind = 'off' and e->'pricing'->>'price' is not null and coalesce(e->>'heading','') <> ''
  ), ins as (
    insert into tjek_offers as t (id, store, catalog_id, catalog, heading, description, price, pre_price,
                                  size_from, size_to, unit, qty_si, si_unit, valid_from, valid_to)
    select distinct on (e->>'id') e->>'id', store, catalog_id, catalog, trim(e->>'heading'), e->>'description',
           (e->'pricing'->>'price')::numeric, (e->'pricing'->>'pre_price')::numeric,
           (e->'quantity'->'size'->>'from')::numeric, (e->'quantity'->'size'->>'to')::numeric,
           e->'quantity'->'unit'->>'symbol',
           round((e->'quantity'->'size'->>'from')::numeric * (e->'quantity'->'unit'->'si'->>'factor')::numeric, 4),
           case e->'quantity'->'unit'->'si'->>'symbol' when 'pcs' then 'stk' else e->'quantity'->'unit'->'si'->>'symbol' end,
           left(e->>'run_from',10)::date, left(e->>'run_till',10)::date
      from o
    on conflict (id) do update set price = excluded.price, pre_price = excluded.pre_price, valid_to = excluded.valid_to, fetched = current_date
    returning 1
  ) select count(*) into n from ins;
  delete from tjek_jobs j using net._http_response r where r.id = j.req_id and j.kind = 'off';
  delete from tjek_offers where valid_to < current_date - 30;
  return jsonb_build_object('tilbud_gemt', n, 'venter', venter,
                            'aktuelle', (select count(*) from tjek_offers where valid_to >= current_date));
end $$;

-- 4) Match mod overvågningslisten med familiens faste regler
create or replace function public.match_offers_test() returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  -- svinekød: stærke ord blokerer altid; "svage" ord (pølse, salami, postej …) kun ok når der står kylling/kalkun/fisk …
  strong text := '(svin|skinke|bacon|flæsk|medister|rullepølse|hamburgerryg|kamsteg|nakkefilet|nakkekotelet|ribbensteg|spareribs|pepperoni|serrano|prosciutto|chorizo|leverpostej|frikadelle|wienerpølse|grillpølse|hotdogpølse|spegepølse|mortadella|kassler|pulled pork|porchetta|(^|[^a-zæøåäöüé])gris($|[^a-zæøåäöüé]))';
  weak   text := '(pølse|salami|postej|paté|pate|frankfurter)';
  safe   text := '(kylling|kalkun|fjerkræ|fisk|laks|tun|reje|vegansk|vegetar|plantebaseret|veggie)';
  beef   text := '(okse|kalv|entrecote|rumpsteak|ribeye|tournedos|culotte|flanksteak|cevapcici|hakket kød|hakkebøf|burgerbøf|hamburgerbøf|roastbeef|pastrami|angus|wagyu)';
begin
  delete from offer_test;
  insert into offer_test (key, name, offer_id, store, heading, price, pre_price, size, offer_unit, ref_unit, saving, valid_from, valid_to, status, reason)
  with o as (
    select t.*, lower(translate(t.heading, 'ÆØÅÄÖÜÉ', 'æøåäöüé')) as hl,
           lower(translate(t.heading || ' ' || coalesce(t.description,''), 'ÆØÅÄÖÜÉ', 'æøåäöüé')) as txt
      from tjek_offers t
     where t.valid_to >= current_date and t.valid_from <= current_date + 4
       -- Lidls faste priser ("Fast lav pris" og det lange katalog maj–dec.) er standardpriser, ikke tilbud
       and not (t.store = 'Lidl' and t.pre_price is null and (coalesce(t.description,'') ~* 'fast\s+lav\s+pris' or t.valid_to - t.valid_from > 35))
  ), m as (
    select w.*, o.id as oid, o.store, o.heading, o.price, o.pre_price, o.qty_si, o.si_unit, o.valid_from, o.valid_to, o.txt,
           coalesce(o.size_from::text,'?') || coalesce(o.unit,'') as size,
           case when o.qty_si > 0 then round(o.price / o.qty_si, 2) end as ou,
           round(w.ref_price / nullif(w.ref_qty,0), 2) as ru
      from o join watch w on w.active and o.hl ~ w.inc and (w.exc is null or o.hl !~ w.exc)
  ), r as (
    select m.*,
      case
        when txt ~ strong then 'svinekød'
        when txt ~ weak and txt !~ safe then 'svinekød (ikke angivet)'
        when txt ~ beef then 'oksekød'
        when req is not null and txt !~ req then 'mangler krav (' || left(req, 30) || ')'
        when ou is null then 'mængde ukendt'
        -- kg og liter regnes som samme enhed (fx sauce i kg eller l)
        when (case when si_unit in ('kg','l') then 'kg' else si_unit end) is distinct from (case when ref_si in ('kg','l') then 'kg' else ref_si end)
          then 'anden enhed (' || coalesce(si_unit,'?') || ')'
        when qty_si < ref_qty * 0.4 or qty_si > ref_qty * 3 then 'anden pakkestørrelse'
        when ou > ru * 0.95 then 'ikke billigere'
        when ou < ru * 0.35 then 'mistænkeligt billig'
        when (ru - ou) * ref_qty * usual < 1.5 then 'under 1,50 kr. sparet'
        else null end as why
      from m
  )
  select key, name, oid, store, heading, price, pre_price, size, ou, ru,
         case when ou is not null and ru is not null then round((ru - ou) * ref_qty, 2) end,
         valid_from, valid_to,
         case when why is null then 'kandidat' else 'afvist' end, why
    from r;
  -- bedste kandidat pr. vare
  update offer_test t set status = 'valgt'
   where status = 'kandidat'
     and offer_id = (select offer_id from offer_test x where x.key = t.key and x.status = 'kandidat'
                      order by x.offer_unit, x.valid_from limit 1);
  return jsonb_build_object(
    'tilbud_vurderet', (select count(distinct offer_id) from offer_test),
    'varer_med_tilbud', (select count(*) from offer_test where status = 'valgt'),
    'kandidater', (select count(*) from offer_test where status in ('valgt','kandidat')),
    'afvist_svinekød', (select count(*) from offer_test where reason like 'svinekød%'),
    'afvist_oksekød', (select count(*) from offer_test where reason = 'oksekød'),
    'afvist_mængde', (select count(*) from offer_test where reason in ('mængde ukendt','anden pakkestørrelse') or reason like 'anden enhed%'),
    'afvist_pris', (select count(*) from offer_test where reason in ('ikke billigere','mistænkeligt billig','under 1,50 kr. sparet')));
end $$;
revoke all on function public.tjek_fetch_catalogs(), public.tjek_fetch_offers(), public.tjek_process(), public.match_offers_test()
  from public, anon, authenticated;
