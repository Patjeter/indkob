create table if not exists items (
  id uuid primary key default gen_random_uuid(),
  text text not null,
  qty text,
  store text,          -- null = jeres input, endnu ikke fordelt
  category text,
  note text,
  suggested boolean not null default false,
  checked boolean not null default false,
  created_at timestamptz not null default now()
);
alter table items enable row level security;
drop policy if exists "familie" on items;
create policy "familie" on items for all to anon using (true) with check (true);
alter publication supabase_realtime add table items;

-- v2: tosprogede navne, katalognøgle og købt-historik
alter table items add column if not exists key text, add column if not exists name_da text, add column if not exists name_sq text;
create table if not exists bought (id bigint generated always as identity primary key, key text not null, at timestamptz not null default now());
alter table bought enable row level security;
create policy familie_bought on bought for all to anon using (true) with check (true);
alter publication supabase_realtime add table bought;

-- v3: tilbud og familiens egne varer
create table if not exists offers (id bigint generated always as identity primary key, key text not null, store text not null, title text, size text, price numeric not null, ref_price numeric, valid_from date, valid_to date not null, note text, created_at timestamptz not null default now());
alter table offers enable row level security;
create policy familie_offers on offers for all to anon using (true) with check (true);
alter publication supabase_realtime add table offers;
create table if not exists products (key text primary key, da text not null, sq text, cat text not null default 'an', store text not null default 'Lidl', created_at timestamptz not null default now());
alter table products enable row level security;
create policy familie_products on products for all to anon using (true) with check (true);
alter publication supabase_realtime add table products;

-- v4: detaljer pr. køb
alter table bought add column if not exists item_id uuid, add column if not exists name_da text, add column if not exists name_sq text, add column if not exists qty integer, add column if not exists store text, add column if not exists price numeric;

-- v23: katalog (varer, priser og købsrytme) ligger i databasen i stedet for i repoet
create table if not exists public.catalog (
  key text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.catalog enable row level security;
create policy "anon all catalog" on public.catalog for all to anon using (true) with check (true);
grant all on public.catalog to anon;

-- v25: lås databasen – kun indloggede brugere på familielisten har adgang
create table if not exists public.family (email text primary key);
alter table public.family enable row level security;
revoke all on public.family from anon, authenticated;
-- insert into public.family(email) values ('<e-mail>');   -- tilføj familiemedlemmer her

create or replace function public.is_family() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.family f where lower(f.email) = lower(coalesce(auth.jwt()->>'email','')))
$$;
revoke all on function public.is_family() from public;
grant execute on function public.is_family() to authenticated;

do $$
declare r record; t text;
begin
  foreach t in array array['items','bought','offers','products','catalog'] loop
    for r in select policyname from pg_policies where schemaname='public' and tablename=t loop
      execute format('drop policy %I on public.%I', r.policyname, t);
    end loop;
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy "kun familien" on public.%I for all to authenticated using (public.is_family()) with check (public.is_family())', t);
  end loop;
end $$;
grant usage, select on all sequences in schema public to authenticated;

-- v30: retter (ingredienser = nøgler i kataloget)
create table if not exists public.dishes (
  id uuid primary key default gen_random_uuid(),
  name_da text not null,
  name_sq text,
  items jsonb not null default '[]'::jsonb,   -- [{"key":"pasta","qty":1}, ...]
  created_at timestamptz not null default now()
);
alter table public.dishes enable row level security;
revoke all on public.dishes from anon;
grant select, insert, update, delete on public.dishes to authenticated;
create policy "kun familien" on public.dishes for all to authenticated using (public.is_family()) with check (public.is_family());
alter publication supabase_realtime add table public.dishes;

-- v31: Al-Rafiden Slagteri, kg-mængder og udskæring
alter table public.bought alter column qty type numeric using qty::numeric;
-- katalog: store="Al-Rafiden Slagteri", unit="kg", step=0.5, forms=[...] for oksekød/hakket oksekød/gullasch

-- v37: tilbud tilføjes kun via denne funktion (bruges af den faste opgave; kun ejer/administrator)
create or replace function public.add_offers(p jsonb) returns integer
language sql security invoker set search_path = public as $fn$
  with ins as (
    insert into public.offers (key, store, title, size, price, ref_price, valid_from, valid_to, note)
    select left(x->>'key',80), x->>'store', left(x->>'title',120), left(x->>'size',40),
           (x->>'price')::numeric, (x->>'ref_price')::numeric, (x->>'valid_from')::date, (x->>'valid_to')::date, left(x->>'note',60)
    from jsonb_array_elements(p) x
    where x->>'store' in ('Lidl','Netto','REMA 1000','føtex','MENY','365discount','SuperBrugsen')
      and (x->>'price')::numeric > 0 and (x->>'ref_price')::numeric > (x->>'price')::numeric
      and (x->>'valid_to')::date >= current_date
      and exists (select 1 from public.catalog c where c.key = x->>'key')
      and not exists (select 1 from public.offers o where o.key = x->>'key' and o.store = x->>'store' and o.valid_to = (x->>'valid_to')::date)
    returning 1)
  select count(*)::int from ins
$fn$;
revoke all on function public.add_offers(jsonb) from public, anon, authenticated;

-- v41: Security Advisor – is_family() uden security definer.
-- En indlogget bruger må kun se sin egen række i family; så kan funktionen køre med brugerens egne rettigheder.
drop policy if exists "egen række" on public.family;
create policy "egen række" on public.family for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt()->>'email','')));
grant select on public.family to authenticated;
create or replace function public.is_family() returns boolean
language sql stable security invoker set search_path = public as $$
  select exists (select 1 from public.family f where lower(f.email) = lower(coalesce(auth.jwt()->>'email','')))
$$;
revoke all on function public.is_family() from public, anon;
grant execute on function public.is_family() to authenticated;
