-- v76: "Køb altid i …" – familiens faste butik for en bestemt vare (fx vasketabletter kun i Netto).
-- Appen lægger varen i den butik, næste gang den tilføjes. Kør i Supabase → SQL Editor.
create table if not exists public.butik_valg (
  key        text primary key,
  store      text not null,
  updated_at timestamptz not null default now(),
  updated_by text default (auth.jwt()->>'email')
);
alter table public.butik_valg enable row level security;
drop policy if exists "kun familien" on public.butik_valg;
create policy "kun familien" on public.butik_valg for all to authenticated
  using (public.is_family()) with check (public.is_family());
revoke all on public.butik_valg from anon;
grant select, insert, update, delete on public.butik_valg to authenticated;
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'butik_valg')
  then alter publication supabase_realtime add table public.butik_valg; end if;
end $$;

-- en vare, familien selv har flyttet til en butik, er ikke et "udløbet tilbud" (appen foreslår ikke at flytte den tilbage)
alter table public.items add column if not exists store_fixed boolean not null default false;
