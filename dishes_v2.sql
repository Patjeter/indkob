-- Retter v2: to slags (retter og madpakker), mærker og link til opskrift.
-- Køres én gang i Supabase SQL Editor. Ændrer ikke eksisterende retter ud over standardværdier.
alter table public.dishes add column if not exists kind text not null default 'ret';
alter table public.dishes add column if not exists tags text[] not null default '{}';
alter table public.dishes add column if not exists link text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'dishes_kind_chk') then
    alter table public.dishes add constraint dishes_kind_chk check (kind in ('ret','madpakke'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'dishes_link_chk') then
    alter table public.dishes add constraint dishes_link_chk check (link is null or link ~ '^https://');
  end if;
end $$;
