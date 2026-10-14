-- v75: "Kan du handle nu?" – én i familien spørger, de andre får en besked og svarer "Jeg tager den" eller "Nej".
-- Den, der spurgte, får besked om svaret. En forespørgsel gælder i 3 timer, eller til nogen tager den.
-- Kør i Supabase → SQL Editor. Kræver push.sql og cron_secret.sql.

create table if not exists public.handle_req (
  id         uuid primary key default gen_random_uuid(),
  asked_by   text not null,                 -- e-mail
  asked_name text,
  asked_dev  text,
  n          int,                           -- antal varer på listen, da der blev spurgt
  created_at timestamptz not null default now(),
  taken_by   text,
  taken_name text,
  taken_at   timestamptz,
  answers    jsonb not null default '[]',   -- [{email, name, svar: 'ja'|'nej', at}]
  closed     boolean not null default false
);
alter table public.handle_req enable row level security;
drop policy if exists "kun familien" on public.handle_req;
create policy "kun familien" on public.handle_req for select to authenticated using (public.is_family());
revoke all on public.handle_req from anon, authenticated;
grant select on public.handle_req to authenticated;          -- ændringer kun via funktionerne nedenfor
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'handle_req')
  then alter publication supabase_realtime add table public.handle_req; end if;
end $$;

-- navnet, beskeden viser (family.name, ellers e-mailens første del)
update public.family set name = 'Valentina' where name is null and email ilike 'valentina%';
create or replace function public.family_name(mail text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select name from family where lower(email) = lower(mail)),
                  initcap(split_part(split_part(coalesce(mail, ''), '@', 1), '.', 1)))
$$;
revoke all on function public.family_name(text) from public, anon, authenticated;

-- send til push-funktionen (samme hemmelighed som de planlagte kørsler)
create or replace function public.handle_push(body jsonb) returns void
language sql security definer set search_path = public as $$
  select null::void from (select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := body)) x
$$;
revoke all on function public.handle_push(jsonb) from public, anon, authenticated;

-- spørg: lukker egne tidligere forespørgsler og sender besked til de andre
create or replace function public.handle_spoerg(dev text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me text := lower(coalesce(auth.jwt()->>'email', '')); rid uuid;
begin
  if not public.is_family() then raise exception 'ingen adgang'; end if;
  if exists (select 1 from handle_req where lower(asked_by) = me and created_at > now() - interval '1 minute')
    then raise exception 'du har lige spurgt'; end if;
  update handle_req set closed = true where lower(asked_by) = me and not closed;
  insert into handle_req (asked_by, asked_name, asked_dev, n)
  values (me, family_name(me), left(dev, 64), (select count(*) from items where not checked))
  returning id into rid;
  perform handle_push(jsonb_build_object('handle', rid));
  return rid;
end $$;
revoke all on function public.handle_spoerg(text) from public, anon;
grant execute on function public.handle_spoerg(text) to authenticated;

-- svar: 'ja' tager indkøbet (den første vinder), 'nej' giver den, der spurgte, besked
create or replace function public.handle_svar(rid uuid, svar text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me text := lower(coalesce(auth.jwt()->>'email', '')); r handle_req;
begin
  if not public.is_family() then raise exception 'ingen adgang'; end if;
  if svar not in ('ja', 'nej') then raise exception 'ugyldigt svar'; end if;
  select * into r from handle_req where id = rid for update;
  if not found or r.closed or r.created_at < now() - interval '3 hours' then return jsonb_build_object('ok', false, 'grund', 'lukket', 'taget_af', r.taken_name); end if;
  if lower(r.asked_by) = me then return jsonb_build_object('ok', false, 'grund', 'egen'); end if;
  if exists (select 1 from jsonb_array_elements(r.answers) a where lower(a->>'email') = me and a->>'svar' = svar)
    then return jsonb_build_object('ok', true, 'gentaget', true); end if;
  update handle_req set
    answers  = answers || jsonb_build_array(jsonb_build_object('email', me, 'name', family_name(me), 'svar', svar, 'at', now())),
    taken_by = case when svar = 'ja' then me else taken_by end,
    taken_name = case when svar = 'ja' then family_name(me) else taken_name end,
    taken_at = case when svar = 'ja' then now() else taken_at end,
    closed   = (svar = 'ja')
  where id = rid;
  perform handle_push(jsonb_build_object('handle_svar', rid, 'email', me, 'svar', svar));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.handle_svar(uuid, text) from public, anon;
grant execute on function public.handle_svar(uuid, text) to authenticated;

-- fortryd: den, der spurgte, kan trække spørgsmålet tilbage
create or replace function public.handle_luk(rid uuid) returns void
language sql security definer set search_path = public as $$
  update handle_req set closed = true
   where id = rid and public.is_family() and lower(asked_by) = lower(coalesce(auth.jwt()->>'email', ''));
$$;
revoke all on function public.handle_luk(uuid) from public, anon;
grant execute on function public.handle_luk(uuid) to authenticated;
