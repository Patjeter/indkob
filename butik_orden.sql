-- Butikkens rækkefølge: familiens egen rækkefølge af kategorier pr. butik.
-- Appen lærer også rækkefølgen af sig selv ud fra, hvornår varerne krydses af (tabellen bought).
create table if not exists public.butik_orden (
  store text primary key,
  cats text[] not null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
alter table public.butik_orden enable row level security;
revoke all on public.butik_orden from anon, public;
grant select, insert, update, delete on public.butik_orden to authenticated;
drop policy if exists "kun familien" on public.butik_orden;
create policy "kun familien" on public.butik_orden for all to authenticated using (public.is_family()) with check (public.is_family());
