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
