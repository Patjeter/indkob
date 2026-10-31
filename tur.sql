-- v78: Næste tur i Kastrup.
--  1) jeres butikker (familie_indstilling 'butikker'): tilbud og turforslag kun fra dem
--  2) seneste pris pr. vare fra kvitteringerne (pakningen I faktisk købte), så listen ikke viser et gennemsnit
--  3) besked på telefonen, når det er værd at handle i dag (tilvalg pr. telefon: push_subs.tur)
-- Kør i Supabase → SQL Editor. Kræver schema.sql, push.sql, cron_secret.sql, tilbud_auto.sql, lidl_priser.sql, kvit.sql.

-- 1) familiens indstillinger
create table if not exists public.familie_indstilling (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by text default (auth.jwt()->>'email')
);
alter table public.familie_indstilling enable row level security;
drop policy if exists "kun familien" on public.familie_indstilling;
create policy "kun familien" on public.familie_indstilling for all to authenticated
  using (public.is_family()) with check (public.is_family());
revoke all on public.familie_indstilling from anon;
grant select, insert, update, delete on public.familie_indstilling to authenticated;
-- Besniks butikker (31/10): alle 7 kæder; Let-Køb står med, men appen henter ikke tilbud derfra
insert into public.familie_indstilling (key, value) values
  ('butikker', '["Lidl","Netto","365discount","REMA 1000","føtex","MENY","SuperBrugsen"]'::jsonb),
  ('butik_adresser', '[{"kaede": "Lidl", "adresse": "Amager Landevej 42, Tårnby"}, {"kaede": "Lidl", "adresse": "Amager Landevej 244, Tårnby"}, {"kaede": "Netto", "adresse": "Amager Landevej 30–32, Tårnby"}, {"kaede": "Netto", "adresse": "Kastrupgård, Kastrupvej 326"}, {"kaede": "365discount", "adresse": "Kastrupvej 223, Kastrup"}, {"kaede": "365discount", "adresse": "Løjtegårdsvej, Amager Landevej 196"}, {"kaede": "REMA 1000", "adresse": "Willumsvej 2, København S"}, {"kaede": "føtex", "adresse": "Amagerbrogade 290"}, {"kaede": "SuperBrugsen", "adresse": "Amagerbrogade 266"}, {"kaede": "MENY", "adresse": "Tårnbyvej 51, Tårnby"}, {"kaede": "Let-Køb", "adresse": "Skottegården 4, Kastrup"}]'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'familie_indstilling')
  then alter publication supabase_realtime add table public.familie_indstilling; end if;
end $$;

-- 2) seneste pris pr. vare (de sidste 120 dage), med pakningens navn fra kvitteringen
create or replace view public.seneste_pris with (security_invoker = true) as
  select distinct on (l.key) l.key, l.navn, round(l.beloeb / nullif(l.antal, 0), 2) as pris, k.dato::date as dato
    from public.kvit_linjer l join public.kvit k using (tid)
   where l.key is not null and l.key <> '-' and l.antal > 0 and l.antal = round(l.antal)
     and k.dato > now() - interval '120 days'
   order by l.key, k.dato desc, l.nr;
revoke all on public.seneste_pris from anon;
grant select on public.seneste_pris to authenticated;

-- 3) besked om en god tur
alter table public.push_subs add column if not exists tur boolean not null default false;

-- hvad kan spares i dag i jeres butikker på det, I skal bruge: varerne på listen + det, der efter købsrytmen
-- slipper op inden for 3 dage. Besparelsen = tilbuddets førpris for jeres pakning minus tilbudsprisen.
create or replace function public.tur_forslag() returns table(store text, n int, spar numeric, top text)
language sql stable security invoker set search_path = public as $$
  with st as (select jsonb_array_elements_text(value) as store from familie_indstilling where key = 'butikker'),
  need as (
    select i.key from items i where not i.checked and i.key is not null
    union
    select c.key from catalog c
     where (c.data->>'every') is not null and coalesce((c.data->>'n')::int, 0) >= 4
       and (c.data->>'last') is not null
       and (c.data->>'last')::date + (c.data->>'every')::int <= current_date + 3
  ),
  o as (
    select distinct on (o.key, o.store) o.key, o.store, o.title, o.price,
           coalesce(o.ref_price, a.normal_fam, (c.data->>'price')::numeric) as ref
      from offers o
      join need using (key)
      left join lidl_alt a on a.key = o.key
      left join catalog c on c.key = o.key
     where o.source in ('auto', 'valg') and o.valid_to >= current_date
       and coalesce(o.valid_from, current_date) <= current_date
       and o.store in (select store from st)
     order by o.key, o.store, o.price
  ),
  s as (select store, key, title, price, round(ref - price, 2) as spar from o where ref > price)
  select store, count(*)::int, sum(spar),
         (array_agg(title || ' ' || replace(to_char(price, 'FM9990.00'), '.', ',') || ' kr.' order by spar desc))[1]
    from s group by store
   order by sum(spar) desc
$$;
revoke all on function public.tur_forslag() from public, anon;
grant execute on function public.tur_forslag() to authenticated;

create table if not exists public.tur_sendt (dato date primary key, tekst text not null);
alter table public.tur_sendt enable row level security;
revoke all on public.tur_sendt from anon, authenticated;

-- teksten til beskeden, eller null når det ikke er turen værd (mindst 40 kr. i én butik).
-- Samme forslag som i går sendes ikke igen.
create or replace function public.tur_besked() returns jsonb
language plpgsql volatile security invoker set search_path = public as $$
declare b record; v_tekst text;
begin
  select * into b from tur_forslag() limit 1;
  if not found or b.spar < 40 then return null; end if;
  v_tekst := format('%s sparer %s kr. på %s %s, fx %s', b.store, round(b.spar), b.n,
                    case when b.n = 1 then 'vare' else 'varer' end, b.top);
  if exists (select 1 from tur_sendt t where t.dato = current_date - 1 and t.tekst = v_tekst)
     or exists (select 1 from tur_sendt t where t.dato = current_date) then return null; end if;
  insert into tur_sendt (dato, tekst) values (current_date, v_tekst);
  delete from tur_sendt t where t.dato < current_date - 30;
  return jsonb_build_object('title', 'Værd at handle i dag', 'body', v_tekst);
end $$;
revoke all on function public.tur_besked() from public, anon, authenticated;

-- hverdage kl. 13.30 UTC (14.30 vinter / 15.30 sommer): før man tager hjem fra arbejde
select cron.unschedule('indkob-tur') where exists (select 1 from cron.job where jobname = 'indkob-tur');
select cron.schedule('indkob-tur', '30 13 * * 1-5', $c$
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := jsonb_build_object('tur', b))
  from (select public.tur_besked() as b) x where b is not null;
$c$);
