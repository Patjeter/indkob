-- v45: Lidls prisregister – normalpriser for hele det sortiment, der dukker op i Lidls kataloger
-- Kilde: Tjek-API'et (samme som tilbudsopgaven). Hentes dagligt af databasen selv (pg_net + pg_cron), se nederst.
--   "Fast lav pris"-kataloget  → standardpris (normal_kind = 'fast')
--   ugens tilbud med førpris   → normalpris = førpris (normal_kind = 'før'), tilbudspris gemmes også
--   tilbud uden førpris        → kun tilbudspris (normalpris kendes fra tidligere eller senere)
-- Kør i Supabase → SQL Editor.

create table if not exists public.lidl_products (
  pkey         text primary key,                 -- normaliseret overskrift | størrelse+enhed
  heading      text not null,                    -- fx "MILBONA Letsaltet smør eller smørbar"
  brand        text,                             -- fx "MILBONA"
  own_brand    boolean not null default false,   -- Lidls eget mærke
  size_from    numeric,
  size_to      numeric,
  unit         text,                             -- g, kg, ml, l, pcs …
  qty_si       numeric,                          -- mængde i kg / l / stk (til enhedspris)
  si_unit      text,                             -- kg, l, stk
  normal_price numeric,
  normal_kind  text check (normal_kind in ('fast','før')),
  normal_seen  date,
  offer_price  numeric,
  offer_from   date,
  offer_to     date,
  unit_price   numeric generated always as (case when qty_si > 0 then round(coalesce(normal_price, offer_price) / qty_si, 2) end) stored,
  first_seen   date not null default current_date,
  last_seen    date not null default current_date
);

create table if not exists public.lidl_price_obs (
  offer_id    text not null,                     -- Tjek-tilbuddets id
  pkey        text not null references public.lidl_products(pkey) on delete cascade,
  seen        date not null default current_date,
  price       numeric not null,
  pre_price   numeric,
  fast        boolean not null default false,
  valid_from  date,
  valid_to    date,
  primary key (offer_id, pkey)
);
create index if not exists lidl_price_obs_pkey on public.lidl_price_obs(pkey, seen);

alter table public.lidl_products  enable row level security;
alter table public.lidl_price_obs enable row level security;
drop policy if exists "kun familien" on public.lidl_products;
drop policy if exists "kun familien" on public.lidl_price_obs;
create policy "kun familien" on public.lidl_products  for select to authenticated using (public.is_family());
create policy "kun familien" on public.lidl_price_obs for select to authenticated using (public.is_family());
revoke all on public.lidl_products, public.lidl_price_obs from anon;
revoke insert, update, delete on public.lidl_products, public.lidl_price_obs from authenticated;
grant select on public.lidl_products, public.lidl_price_obs to authenticated;

-- Indlæsning: én række pr. tilbud fra Edge Function. Returnerer optælling.
create or replace function public.lidl_ingest(rows jsonb) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare
  r jsonb; is_new boolean; n_new int := 0; n_obs int := 0; n_normal int := 0;
  v_normal numeric; v_kind text; v_offer numeric;
begin
  for r in select * from jsonb_array_elements(rows) loop
    continue when coalesce(r->>'pkey','') = '' or (r->>'price') is null;
    if (r->>'fast')::boolean then v_normal := (r->>'price')::numeric; v_kind := 'fast'; v_offer := null;
    elsif (r->>'pre_price') is not null and (r->>'pre_price')::numeric > (r->>'price')::numeric then
      v_normal := (r->>'pre_price')::numeric; v_kind := 'før'; v_offer := (r->>'price')::numeric;
    else v_normal := null; v_kind := null; v_offer := (r->>'price')::numeric;
    end if;

    insert into lidl_products as p (pkey, heading, brand, own_brand, size_from, size_to, unit, qty_si, si_unit,
                                     normal_price, normal_kind, normal_seen, offer_price, offer_from, offer_to)
    values (r->>'pkey', r->>'heading', nullif(r->>'brand',''), coalesce((r->>'own')::boolean,false),
            (r->>'size_from')::numeric, (r->>'size_to')::numeric, r->>'unit', (r->>'qty_si')::numeric, r->>'si_unit',
            v_normal, v_kind, case when v_normal is not null then current_date end,
            v_offer, case when v_offer is not null then (r->>'valid_from')::date end, case when v_offer is not null then (r->>'valid_to')::date end)
    on conflict (pkey) do update set
      heading      = excluded.heading,
      brand        = excluded.brand,
      own_brand    = excluded.own_brand,
      last_seen    = current_date,
      normal_price = coalesce(excluded.normal_price, p.normal_price),
      normal_kind  = coalesce(excluded.normal_kind,  p.normal_kind),
      normal_seen  = coalesce(excluded.normal_seen,  p.normal_seen),
      offer_price  = case when excluded.offer_price is not null then excluded.offer_price else p.offer_price end,
      offer_from   = case when excluded.offer_price is not null then excluded.offer_from  else p.offer_from  end,
      offer_to     = case when excluded.offer_price is not null then excluded.offer_to    else p.offer_to    end
    returning (xmax = 0) into is_new;
    if is_new then n_new := n_new + 1; end if;
    if v_normal is not null then n_normal := n_normal + 1; end if;

    insert into lidl_price_obs (offer_id, pkey, price, pre_price, fast, valid_from, valid_to)
    values (r->>'id', r->>'pkey', (r->>'price')::numeric, (r->>'pre_price')::numeric, coalesce((r->>'fast')::boolean,false),
            (r->>'valid_from')::date, (r->>'valid_to')::date)
    on conflict do nothing;
    if found then n_obs := n_obs + 1; end if;
  end loop;
  return jsonb_build_object('rækker', jsonb_array_length(rows), 'nye_varer', n_new, 'med_normalpris', n_normal, 'nye_observationer', n_obs,
                            'varer_i_alt', (select count(*) from lidl_products),
                            'med_normalpris_i_alt', (select count(*) from lidl_products where normal_price is not null));
end $$;
revoke all on function public.lidl_ingest(jsonb) from public, anon, authenticated;
grant execute on function public.lidl_ingest(jsonb) to service_role;

-- Hentning sker i databasen selv (pg_net), fordi Tjek afviser Supabases Edge-servere.
-- 04:20 UTC: lidl_fetch() bestiller siderne · 04:25 UTC: lidl_process() læser svarene og gemmer priserne.
create table if not exists public.lidl_fetch_jobs (req_id bigint primary key, created_at timestamptz not null default now());
alter table public.lidl_fetch_jobs enable row level security;
revoke all on public.lidl_fetch_jobs from anon, authenticated;

create or replace function public.lidl_fetch() returns int
language plpgsql security invoker set search_path = public, extensions as $$
declare off int; n int := 0;
begin
  delete from lidl_fetch_jobs where created_at < now() - interval '1 day';
  for off in 0..1400 by 100 loop
    insert into lidl_fetch_jobs(req_id) values (net.http_get(
      url := format('https://squid-api.tjek.com/v2/offers?dealer_ids=71c90&r_lat=55.6337&r_lng=12.6360&r_radius=10000&limit=100&offset=%s', off),
      timeout_milliseconds := 30000));
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.lidl_process() returns jsonb
language plpgsql security invoker set search_path = public, extensions as $$
declare
  own text[] := array['MILBONA','ENGVANG','MADVÆRKET','BAKKEDAL','LOVILIO','DULANO','CROWNFIELD','BELLAROM','SONDEY','ALESTO','VEMONDO','CIEN','DENTALUX','W5','FORMIL','LUPILU','COMBINO','BARESA','FIN CARRÉ','SASKIA','SOLEVITA','KANIA','SNACK DAY','FAVORINA','FREEWAY','TASTINO','PERLENBACHER','DELUXE','BELBAKE','ITALIAMO','GELATELLI','CHEF SELECT','VITA D''OR','MCENNEDY','EXQUISITA','PILOS','HAVBLÅ','BUTCHER''S','BUTCHER’S','CHOCO NUSSA','BIO ORGANIC','MARIBEL','NIXE','SIEMPRE','FLORALYS','AROMATA','LIBA','GOLDEN SEAFOOD','OCEAN SEA','CRIVIT','PARKSIDE','SILVERCREST','LIVARNO','ESMARA','LIVERGY','PEPPERTS','SUN SNACKS','TRATTORIA ALFREDO','CUISINE ROYAL','LACTOFREE','LACTO FREE','BLUE WATER','ECHT NORDISCH','MARTAKA','GOLDEN BRIDGE','VITASIA','SOL & MAR','EL TEQUITO','SNACK TIME','HATHERWOOD','J.D. GROSS','MIREE','RIVERCOTE','MOMENTS','ROMANI','DEN GAMLE FABRIK','MARLENE','PRIMADONNA'];
  rows jsonb; res jsonb; venter int; sider int;
begin
  select count(*) filter (where r.id is null), count(*) filter (where r.status_code = 200)
    into venter, sider
    from lidl_fetch_jobs j left join net._http_response r on r.id = j.req_id;
  with resp as (
    select r.content::jsonb as arr
      from lidl_fetch_jobs j join net._http_response r on r.id = j.req_id
     where r.status_code = 200 and left(r.content, 1) = '['
  ), o as (
    select e from resp, jsonb_array_elements(resp.arr) e
     where e->'pricing'->>'price' is not null and coalesce(e->>'heading','') <> ''
  ), b as (
    select e,
           trim(coalesce((regexp_match(e->>'heading', '^((?:[^\sa-zæøåäöüé]*[A-ZÆØÅÄÖÜÉ][^\sa-zæøåäöüé]*\s+)+)'))[1], '')) as brand,
           (e->'quantity'->'size'->>'from')::numeric as sf,
           coalesce((e->'quantity'->'size'->>'to')::numeric, (e->'quantity'->'size'->>'from')::numeric) as st,
           coalesce(e->'quantity'->'unit'->>'symbol', '') as sym,
           e->'quantity'->'unit'->'si'->>'symbol' as si,
           (e->'quantity'->'unit'->'si'->>'factor')::numeric as fac
      from o
  )
  select jsonb_agg(jsonb_build_object(
           'id', e->>'id',
           'pkey', trim(lower(regexp_replace(e->>'heading', '[\s,.;:!?()"/–-]+', ' ', 'g'))) || '|' ||
                   case when sf is null then '' when st = sf then sf::text else sf::text || '-' || st::text end || sym,
           'heading', trim(e->>'heading'),
           'brand', brand,
           'own', brand <> '' and exists (select 1 from unnest(own) x where upper(brand) like x || '%'),
           'size_from', sf, 'size_to', st, 'unit', nullif(sym, ''),
           'qty_si', case when sf is not null and fac is not null then round(sf * fac, 4) end,
           'si_unit', case si when 'pcs' then 'stk' else si end,
           'price', (e->'pricing'->>'price')::numeric,
           'pre_price', (e->'pricing'->>'pre_price')::numeric,
           'fast', coalesce(e->>'description', '') ~* 'fast\s+lav\s+pris',
           'valid_from', left(e->>'run_from', 10), 'valid_to', left(e->>'run_till', 10)))
    into rows from b;
  res := lidl_ingest(coalesce(rows, '[]'::jsonb));
  delete from lidl_fetch_jobs j using net._http_response r where r.id = j.req_id;
  return res || jsonb_build_object('sider', sider, 'venter', venter);
end $$;
revoke all on function public.lidl_fetch(), public.lidl_process() from public, anon, authenticated;

select cron.unschedule(jobname) from cron.job where jobname in ('lidl-priser', 'lidl-hent', 'lidl-gem');
select cron.schedule('lidl-hent', '20 4 * * *', $c$ select public.lidl_fetch(); $c$);
select cron.schedule('lidl-gem',  '25 4 * * *', $c$ select public.lidl_process(); $c$);

-- v48: Lidls standardpriser kobles på familiens faste varer (watch)
--   normal_* = Lidls aktuelle pris på det produkt, I plejer at købe (genkendt på mærke/første ord i jeres kvitteringsnavn)
--   own_*    = billigste Lidl-eget mærke til samme slags vare, når I i dag køber et andet mærke
create table if not exists public.lidl_alt (
  key text primary key,
  normal_heading text, normal_price numeric, normal_size text, normal_unit numeric, normal_fam numeric,
  own_heading text, own_price numeric, own_size text, own_unit numeric, own_save numeric,
  updated date not null default current_date
);
alter table public.lidl_alt enable row level security;
drop policy if exists "kun familien" on public.lidl_alt;
create policy "kun familien" on public.lidl_alt for select to authenticated using (public.is_family());
revoke all on public.lidl_alt from anon;
revoke insert, update, delete on public.lidl_alt from authenticated;
grant select on public.lidl_alt to authenticated;

create or replace function public.lidl_alt_refresh() returns jsonb
language plpgsql security invoker set search_path = public as $$
declare c_norm int; c_own int;
begin
  delete from lidl_alt;
  insert into lidl_alt (key, normal_heading, normal_price, normal_size, normal_unit, normal_fam,
                        own_heading, own_price, own_size, own_unit, own_save)
  with w as (
    select w.*, lower(translate(split_part(coalesce(c.data->'prod'->>0, w.name), ' ', 1), 'ÆØÅÄÖÜÉ', 'æøåäöüé')) as fw
      from watch w join catalog c on c.key = w.key where w.active
  ), lp as (
    select p.*, lower(translate(p.heading, 'ÆØÅÄÖÜÉ', 'æøåäöüé')) as hl
      from lidl_products p
     where p.normal_price is not null and p.normal_seen >= current_date - 90 and p.unit_price is not null
  ), m as (
    select w.key, w.fw, w.ref_qty, w.ref_price, lp.*
      from w join lp on lp.hl ~ w.inc and (w.exc is null or lp.hl !~ w.exc) and (w.req is null or lp.hl ~ w.req)
       and (case when lp.si_unit in ('kg','l') then 'kg' else lp.si_unit end) = (case when w.ref_si in ('kg','l') then 'kg' else w.ref_si end)
       and lp.qty_si between w.ref_qty * 0.4 and w.ref_qty * 3
       -- samme sikkerhedsregler som tilbuddene: aldrig svin eller okse
       and lp.hl !~ '(svin|skinke|bacon|flæsk|medister|rullepølse|hamburgerryg|kamsteg|spegepølse|leverpostej|frikadelle|pepperoni|chorizo|okse|kalv|entrecote|rumpsteak|cevapcici|roastbeef)'
  ), nrm as (            -- jeres eget produkt hos Lidl
    select distinct on (key) * from m where length(fw) >= 3 and position(fw in hl) > 0
       -- sikkerhedstjek: ligger prisen langt fra det, I plejer at betale, er det næppe samme produkt
       and unit_price between ref_price / nullif(ref_qty,0) * 0.6 and ref_price / nullif(ref_qty,0) * 1.4
     order by key, normal_seen desc, unit_price
  ), own as (            -- billigste Lidl-eget alternativ
    select distinct on (key) * from m where own_brand order by key, unit_price
  ), x as (
    select w.key, w.ref_qty,
           n.heading nh, n.normal_price np, coalesce(n.size_from::text,'') || coalesce(n.unit,'') ns, n.unit_price nu, n.own_brand n_own, n.pkey npk,
           o.heading oh, o.normal_price op, coalesce(o.size_from::text,'') || coalesce(o.unit,'') os, o.unit_price ou, o.pkey opk,
           coalesce(n.unit_price, w.ref_price / nullif(w.ref_qty,0)) fam_unit
      from w left join nrm n on n.key = w.key left join own o on o.key = w.key
  )
  select key, nh, np, ns, nu, round(nu * ref_qty, 2),
         case when show_own then oh end, case when show_own then op end, case when show_own then os end, case when show_own then ou end,
         case when show_own then round((fam_unit - ou) * ref_qty, 2) end
    from (select x.*, (oh is not null and coalesce(n_own, false) = false and opk is distinct from npk
                       and ou <= fam_unit * 0.9 and (fam_unit - ou) * ref_qty >= 1.5) as show_own from x) y
   where nh is not null or show_own;
  select count(*) filter (where normal_price is not null), count(*) filter (where own_price is not null) into c_norm, c_own from lidl_alt;
  return jsonb_build_object('lidl_pris_på_jeres_vare', c_norm, 'lidls_eget_alternativ', c_own);
end $$;
revoke all on function public.lidl_alt_refresh() from public, anon, authenticated;

select cron.unschedule(jobname) from cron.job where jobname = 'lidl-alt';
select cron.schedule('lidl-alt', '28 4 * * *', $c$ select public.lidl_alt_refresh(); $c$);
