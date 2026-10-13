-- v51: kvitteringer i databasen – holder købsrytme, priser og "plejer" opdateret af sig selv
-- Kvitteringer kommer ind gennem appen (import fra lidl.dk, senere scanning af andre butikker).
-- Hver varelinje kobles til en vare i kataloget:
--   1) kvit_regler: mønstre for de faste varer (samme som appens katalog blev bygget med)
--   2) kvit_navne:  kendte kvitteringsnavne → vare ('-' = ignoreres, fx pant og non-food)
-- Ukendte navne gemmes uden vare og kan kobles senere.
-- kvit_rytme() regner købsrytmen (n, sidst, mellemrum, typisk antal, typisk pris, produktnavne)
-- om ud fra ALLE kvitteringer – samme regler som build_catalog.py.
-- Kør i Supabase → SQL Editor. Indholdet (kvitteringer, navne) indlæses separat og ligger aldrig i repoet.

create table if not exists public.kvit (
  tid          text primary key,                  -- Lidls kvitterings-id (eller scanningens id)
  dato         timestamptz not null,
  butik        text,
  kaede        text not null default 'Lidl',
  total        numeric,
  parsed_total numeric,
  ejer         text,                              -- hvis konto: besnik / valentina
  kilde        text not null default 'lidl.dk',
  indlaest     timestamptz not null default now(),
  indlaest_af  text default (auth.jwt()->>'email')
);
create table if not exists public.kvit_linjer (
  tid      text not null references public.kvit(tid) on delete cascade,
  nr       int  not null,
  navn     text not null,
  antal    numeric not null default 1,
  stk_pris numeric,
  beloeb   numeric not null,
  rabat    numeric not null default 0,
  key      text,                                  -- null = ukendt, '-' = ignoreres
  primary key (tid, nr)
);
create index if not exists kvit_linjer_key on public.kvit_linjer(key);
create table if not exists public.kvit_navne  (navn text primary key, key text not null);
create table if not exists public.kvit_regler (nr int primary key, key text not null, pat text not null);

do $$ declare t text; begin
  foreach t in array array['kvit','kvit_linjer','kvit_navne','kvit_regler'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "kun familien" on public.%I', t);
    execute format('create policy "kun familien" on public.%I for all to authenticated using (public.is_family()) with check (public.is_family())', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- navn som i kataloget: mellemrum samlet, varenummer i enden fjernet, små bogstaver
create or replace function public.kvit_clean(n text) returns text language sql immutable as $$
  select lower(translate(btrim(regexp_replace(regexp_replace(regexp_replace(n, '\s+', ' ', 'g'), ',\d{6,}$', ''), '\s*0\d{6}$', '')),
                         'ÆØÅÄÖÜÉ', 'æøåäöüé'))
$$;

create or replace function public.kvit_key(n text, beloeb numeric default 1) returns text
language sql stable security invoker set search_path = public as $$
  select case
    when beloeb <= 0 or lower(n) ~ '(^|[^a-zæøå])pant($|[^a-zæøå])' then '-'
    else coalesce(
      (select r.key from kvit_regler r
        where lower(translate(regexp_replace(n, '\s+', ' ', 'g'), 'ÆØÅÄÖÜÉ', 'æøåäöüé')) ~ r.pat order by r.nr limit 1),
      (select v.key from kvit_navne v where v.navn = kvit_clean(n)))
  end
$$;

-- Købsrytme pr. vare ud fra alle kvitteringer (som build_catalog.py). keys = null → alle varer.
create or replace function public.kvit_rytme(keys text[] default null) returns int
language plpgsql security invoker set search_path = public as $$
declare newest date; y1 date; y2 date; n_upd int;
begin
  select max(dato::date) into newest from kvit;
  if newest is null then return 0; end if;
  y1 := newest - 365; y2 := newest - 730;
  with l as (
    select l.key, k.dato::date as d, l.antal, l.beloeb, l.rabat, l.navn
      from kvit_linjer l join kvit k using (tid)
     where l.key is not null and l.key <> '-' and (keys is null or l.key = any(keys))
  ), pd as (            -- pr. vare og dag
    select key, d,
           sum(case when antal = trunc(antal) then antal else 1 end) as q,
           array_agg((beloeb + rabat) / antal) filter (where antal <> 0) as prices
      from l group by key, d
  ), rk as (
    select pd.*, row_number() over (partition by key order by d desc) as rn,
           count(*) filter (where d >= y1) over (partition by key) as n12,
           count(*) filter (where d >= y2) over (partition by key) as n24
      from pd
  ), g as (              -- mellemrum mellem købsdage (seneste 2 år, ellers alle)
    select key, d, d - lag(d) over (partition by key order by d) as gap
      from rk where n24 = 0 or d >= y2
  ), st as (
    select r.key,
           count(*) filter (where r.d >= y1) as n,
           count(*) as nall,
           max(r.d) as last,
           percentile_cont(0.5) within group (order by r.q) filter (where r.rn <= 6) as q6,
           sum(r.q) filter (where r.d >= y1) as tot
      from rk r group by r.key
  ), gp as (
    select key,
           (select jsonb_agg(gap order by d) from (select d, gap from g g2 where g2.key = g.key and gap is not null order by d desc limit 30) x) as gaps,
           percentile_cont(0.5) within group (order by gap) as med
      from g where gap is not null group by key
  ), pr as (
    select key, percentile_cont(0.5) within group (order by p) as price
      from (select key, unnest(prices) as p from rk where rn <= 6) x group by key
  ), nm as (
    select key, jsonb_agg(navn order by c desc, first_d) as prod
      from (select key, navn, count(*) c, min(d) first_d, row_number() over (partition by key order by count(*) desc, min(d)) rn
              from (select key, btrim(regexp_replace(regexp_replace(regexp_replace(navn, '\s+', ' ', 'g'), ',\d{6,}$', ''), '\s*0\d{6}$', '')) navn, d
                      from l where d >= y1) y
             group by key, navn) z
     where rn <= 2 group by key
  ), up as (
    update catalog c set data = c.data || jsonb_build_object(
        'n', st.n, 'nall', st.nall, 'last', st.last,
        'gaps', case when st.n >= 4 then gp.gaps end,
        'every', case when gp.med is not null then round(gp.med) end,
        'qty', greatest(1, round(st.q6)),
        'tot', round(coalesce(st.tot, 0)),
        'prod', coalesce(nm.prod, '[]'::jsonb),
        'price', round(pr.price::numeric, 2)),
      updated_at = now()
      from st left join gp using (key) left join pr using (key) left join nm using (key)
     where c.key = st.key
    returning 1
  )
  select count(*) into n_upd from up;
  return n_upd;
end $$;

-- Indlæsning: [{tid, dato, butik, kaede?, total, parsed_total?, ejer?, kilde?, linjer:[[navn, antal, stk_pris, beloeb, rabat], …]}, …]
-- Kendte kvitteringer springes over. Bagefter: købsrytme for de berørte varer, og varer på listen,
-- som står på en ny kvittering (og blev skrevet på før købet), krydses af.
drop function if exists public.kvit_ingest(jsonb);
create or replace function public.kvit_ingest(rows jsonb, afkryds boolean default true) returns jsonb
language plpgsql security invoker set search_path = public as $$
declare r jsonb; ln jsonb; i int; n_new int := 0; n_lines int := 0; n_known int := 0; ks text[] := '{}'; n_checked int := 0; ukendt jsonb;
begin
  for r in select * from jsonb_array_elements(rows) loop
    insert into kvit (tid, dato, butik, kaede, total, parsed_total, ejer, kilde)
    values (r->>'tid', (r->>'dato')::timestamptz, r->>'butik', coalesce(r->>'kaede','Lidl'), (r->>'total')::numeric,
            (r->>'parsed_total')::numeric, r->>'ejer', coalesce(r->>'kilde','lidl.dk'))
    on conflict (tid) do nothing;
    if not found then n_known := n_known + 1; continue; end if;
    n_new := n_new + 1; i := 0;
    for ln in select * from jsonb_array_elements(r->'linjer') loop
      i := i + 1;
      insert into kvit_linjer (tid, nr, navn, antal, stk_pris, beloeb, rabat, key)
      values (r->>'tid', i, ln->>0, coalesce((ln->>1)::numeric, 1), (ln->>2)::numeric, (ln->>3)::numeric, coalesce((ln->>4)::numeric, 0),
              kvit_key(ln->>0, (ln->>3)::numeric));
      n_lines := n_lines + 1;
    end loop;
    -- afkryds kun det, der faktisk er købt: købte man færre end på listen, bliver resten stående
    with k as (
      select key, sum(coalesce(antal, 1)) as q from kvit_linjer
       where tid = r->>'tid' and key is not null and key <> '-' group by key
    ), upd as (
      update items it
         set checked = (case when it.qty ~ '^\s*[0-9]+([.,][0-9]+)?\s*$' then replace(trim(it.qty), ',', '.')::numeric else 1 end) <= k.q,
             qty = case when (case when it.qty ~ '^\s*[0-9]+([.,][0-9]+)?\s*$' then replace(trim(it.qty), ',', '.')::numeric else 1 end) <= k.q
                        then it.qty
                        else trim(to_char(replace(trim(it.qty), ',', '.')::numeric - k.q, 'FM999990.##'), '.') end
        from k
       where not it.checked and it.key = k.key
         and it.created_at < (r->>'dato')::timestamptz
         and afkryds and (r->>'dato')::timestamptz > now() - interval '7 days'   -- kun nye køb, ikke gamle kvitteringer
      returning it.checked)
    select n_checked + count(*) filter (where checked) into n_checked from upd;
    ks := ks || array(select distinct key from kvit_linjer where tid = r->>'tid' and key is not null and key <> '-');
  end loop;
  if n_new > 0 then perform kvit_rytme(array(select distinct unnest(ks))); end if;
  select coalesce(jsonb_agg(distinct navn), '[]') into ukendt
    from kvit_linjer where key is null and tid in (select x->>'tid' from jsonb_array_elements(rows) x);
  return jsonb_build_object('nye', n_new, 'kendte', n_known, 'linjer', n_lines, 'krydset_af', n_checked,
                            'varer', coalesce(array_length(array(select distinct unnest(ks)), 1), 0), 'ukendte', ukendt);
end $$;
grant execute on function public.kvit_ingest(jsonb, boolean) to authenticated;
grant execute on function public.kvit_rytme(text[]) to authenticated;
revoke all on function public.kvit_ingest(jsonb, boolean) from anon, public;
revoke all on function public.kvit_rytme(text[]) from anon, public;

-- seneste kvittering pr. konto (appen viser, hvornår der sidst er hentet)
create or replace view public.kvit_status with (security_invoker = true) as
  select kilde, max(dato) as seneste, count(*) as antal from public.kvit group by kilde;
grant select on public.kvit_status to authenticated;
