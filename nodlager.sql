-- v80: Nødlager – familiens beredskabslager (Mere → Nødlager).
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
begin new.updated_at := now(); new.updated_by := coalesce(auth.jwt()->>'email', new.updated_by); return new; end $$;
drop trigger if exists nodlager_stempel on public.nodlager;
create trigger nodlager_stempel before update on public.nodlager for each row execute function public.nodlager_stempel();

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'nodlager')
  then alter publication supabase_realtime add table public.nodlager; end if;
end $$;

insert into public.familie_indstilling(key, value) values ('nodlager_uger', '1'::jsonb) on conflict do nothing;
