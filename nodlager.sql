-- v80: Nødlager – familiens beredskabslager (Mere → Nødlager). v81: holdbarhed og besked, når noget skal bruges. v82: billigste pris.
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
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'varslet_for' - 'updated_at' - 'updated_by') = (to_jsonb(old) - 'varslet_for' - 'updated_at' - 'updated_by')
  then return new; end if;   -- kun advarslen er sendt: ikke en ændring fra familien
  new.updated_at := now(); new.updated_by := coalesce(auth.jwt()->>'email', new.updated_by); return new;
end $$;
drop trigger if exists nodlager_stempel on public.nodlager;
create trigger nodlager_stempel before update on public.nodlager for each row execute function public.nodlager_stempel();

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'nodlager')
  then alter publication supabase_realtime add table public.nodlager; end if;
end $$;

insert into public.familie_indstilling(key, value) values ('nodlager_uger', '1'::jsonb) on conflict do nothing;

-- v81: holdbarhed. Appen gemmer navnet (dansk/albansk), datoen for det, der udløber først,
-- og hvor mange dage før man vil advares (varsel). nod_varsel() finder det, der skal bruges snart,
-- og sender én besked pr. dato (varslet_for husker datoen, der er advaret om).
alter table public.nodlager add column if not exists navn text;
alter table public.nodlager add column if not exists navn_sq text;
alter table public.nodlager add column if not exists udloeb date;
alter table public.nodlager add column if not exists varsel smallint not null default 30;
alter table public.nodlager add column if not exists varslet_for date;

create or replace function public.nod_varsel() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_da text; v_sq text; v_n int;
begin
  with due as (
    select n.key, regexp_replace(coalesce(n.navn, n.key), '\s*[(–].*$', '') navn, regexp_replace(coalesce(n.navn_sq, n.navn, n.key), '\s*[(–].*$', '') navn_sq, n.udloeb, n.varsel
    from nodlager n
    where n.uger > 0 and n.udloeb is not null
      and n.udloeb <= current_date + n.varsel
      and n.varslet_for is distinct from n.udloeb
    order by n.udloeb, n.key
  ), mark as (
    update nodlager n set varslet_for = n.udloeb from due where n.key = due.key returning n.key
  )
  select count(*),
         string_agg(format('%s (%s)', d.navn, to_char(d.udloeb, 'FMDD/FMMM')), ', ' order by d.udloeb, d.key),
         string_agg(format('%s (%s)', d.navn_sq, to_char(d.udloeb, 'FMDD/FMMM')), ', ' order by d.udloeb, d.key)
    into v_n, v_da, v_sq
  from due d where d.key in (select key from mark);
  if coalesce(v_n, 0) = 0 then return null; end if;
  return jsonb_build_object(
    'da', jsonb_build_object('title', 'Nødlager: brug det snart',
          'body', left(v_da || ' – brug det i hverdagen, og køb nyt til lageret.', 240)),
    'sq', jsonb_build_object('title', 'Rezerva emergjente: përdoreni së shpejti',
          'body', left(v_sq || ' – përdoreni në përditshmëri dhe blini të reja për rezervën.', 240)));
end $$;
revoke all on function public.nod_varsel() from public, anon, authenticated;

-- hver dag kl. 15.10 UTC (16.10 vinter / 17.10 sommer)
select cron.unschedule('indkob-nodlager') where exists (select 1 from cron.job where jobname = 'indkob-nodlager');
select cron.schedule('indkob-nodlager', '10 15 * * *', $c$
  select net.http_post(
    url     := 'https://onhsmcapojdfzuvcyqsm.supabase.co/functions/v1/push',
    headers := jsonb_build_object('Content-Type','application/json',
               'Authorization','Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uaHNtY2Fwb2pkZnp1dmN5cXNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE3MzM1NjQsImV4cCI6MjEwNzMwOTU2NH0.abpbVEay_4C4EjAFRkX-vDXJ2TRXc9xe6rSPQDXXIWM',
               'x-cron-secret', (select secret from public.cron_secret where id = 1)),
    body    := jsonb_build_object('nod', b))
  from (select public.nod_varsel() as b) x where b is not null;
$c$);

-- v82: billigste pris. nod_vare beskriver de varer til nødlageret, der kan købes (søgning i tilbudsaviser og Lidls priser).
-- nod_priser() finder for hver vare den billigste pris lige nu pr. kg/l (stk.: pr. pakke) i jeres butikker:
-- Lidls faste pris (lidl_soeg) eller et aktuelt tilbud (tjek_offers). Familiens regler (familie_regel) gælder.
create table if not exists public.nod_vare (
  key text primary key, item text not null, navn text not null,
  inc text not null, exc text, req text,
  si text not null check (si in ('kg','l','stk')), uge numeric not null, fast boolean not null default false
);
alter table public.nod_vare enable row level security;
drop policy if exists "kun familien" on public.nod_vare;
create policy "kun familien" on public.nod_vare for select to authenticated using (public.is_family());
revoke all on public.nod_vare from anon;
grant select on public.nod_vare to authenticated;
insert into public.nod_vare (key, item, navn, inc, exc, req, si, uge, fast) values
  ('vand','vand','Kildevand','(kildevand|mineralvand|aqua d.or)','(brus|kulsyre|citron|lime|smag|danskvand|hindbær|æble|appelsin|ingefær|sport|sparkling|med )',null,'l',84,false),
  ('pasta','pasta','Pasta og ris','(spaghetti|penne|fusilli|makaroni|pasta|jasminris|basmati|parboiled|couscous|\bris\b)','(sauce|pesto|frisk|fyldt|tortellini|ravioli|lasagne|salat|ret\b|risotto|grød|kiks|papir|chips|snack|nudler|mel\b|bowl|klar til|microwave|mikro|kogeposer?\s*à\s*\d+\s*g\s*x\s*1\b)',null,'kg',3.5,false),
  ('havre','havre','Havregryn','havregryn','(bar|cookie|drik|mælk|kiks|bage)',null,'kg',2,false),
  ('knaek','knaek','Knækbrød','(knækbrød|wasa|tvebakker|skorper)','(snack|chips|dip|mini)',null,'kg',2,false),
  ('boenner','boenner','Bønner og kikærter','(kikærter|kidneybønner|hvide bønner|sorte bønner|bønner i tomat|baked beans|linser|bønnemix|butterbeans|borlotti)','(chips|snack|hummus|salat|tørrede|frost|pasta|chili con|suppe)',null,'kg',3.2,false),
  ('fisk','fisk','Fisk på dåse','(\btun\b|tunfisk|makrel i|makrelfilet|sardiner|brisling)','(salat|pizza|sandwich|røget|frisk|pålæg|postej|mousse|dressing|steak|loins?|frost|pasta)',null,'kg',1.5,false),
  ('tomat','tomat','Hakkede tomater og passata','(hakkede tomater|flåede tomater|passata|knuste tomater|tomatpuré)','(cherry|snack|soltørrede|friske|ketchup|sauce)',null,'kg',2.4,false),
  ('groent','groent','Grøntsager på dåse','(majs|ærter og gulerødder|grønne bønner|perlebønner|champignon)','(kolbe|popcorn|frost|frosne|frossen|dybfrost|chips|flakes|friske|mel\b|stivelse|baby|snack|kiks|kager|knækbrød|tortilla|crispy|i kurv|bakke)',null,'kg',1.8,false),
  ('frugt','frugt','Tørret frugt','(rosiner|tørrede abrikoser|dadler|tørrede tranebær|tørret frugt|svesker|frugtcocktail|ferskner i|pærer i|ananas i|abrikoser i)','(chokolade|müsli|bar\b|juice|yoghurt)',null,'kg',1.5,false),
  ('noedder','noedder','Nødder og peanutbutter','(peanut butter|peanutbutter|jordnøddesmør|peanuts|cashew|mandler|nøddemix|studenterhavre|valnødder|hasselnødder)','(chokolade|bar\b|is\b|kage|mel\b|drik|mælk|flips|chili|wasabi|smag|honning|saltet karamel|creme|oliven)',null,'kg',1,false),
  ('maelk','maelk','Holdbar mælk','mælk','(laktosefri|kondens|kakao|chokolade|kaffe|kokos|havre|soja|mandel|ris|pulver|is\b|snitte|chokolade)','(uht|holdbar|langtidsholdbar)','l',4,false),
  ('maelk-lf','maelk','Laktosefri holdbar mælk','laktosefri','(kakao|chokolade|kaffe|yoghurt|ost|smør|fløde|is\b|skyr|creme)','(uht|holdbar|langtidsholdbar)','l',2,false),
  ('olie','olie','Olie','(rapsolie|solsikkeolie|olivenolie|vegetabilsk olie)','(spray|chili|hvidløg|basilikum|trøffel)',null,'l',0.5,false),
  ('soedt','soedt','Syltetøj og honning','(syltetøj|marmelade|honning|nutella|chokoladepålæg|nøddepålæg)','(kiks|kage|müsli|yoghurt|te\b|sennep|dressing|bar\b)',null,'kg',1,false),
  ('supper','supper','Suppe på dåse eller pose','(suppe|gullasch)','(urter|horn|boller|terning|bouillon|frisk|frost|ret\b|kødsuppe|svin|flæsk)',null,'kg',3,false),
  ('kaffe','kaffe','Kaffe (Merrild Rød)','merrild',null,null,'kg',0.5,false),
  ('service','service','Køkkenrulle','køkkenrulle',null,null,'stk',2,false),
  ('batterier','batterier','Batterier','(batterier|alkaline)','(genopladelig|oplader|knapcelle|cr2032|9 ?v\b|lithium knap|lader)',null,'stk',12,false),
  ('stearin','stearin','Stearinlys','(stearinlys|kronelys|bloklys|fyrfadslys|antikke lys)','(duft|led|elektrisk|batteri|advent|kalender)',null,'stk',10,false),
  ('toiletpapir','toiletpapir','Toiletpapir','toiletpapir','(fugtig|våd)',null,'stk',8,false),
  ('vaadserv','vaadserv','Vådservietter','(vådservietter|vaadservietter|babyservietter|wet wipes|vådserviet)','(rengøring|gulv|køkken|briller|toilet)',null,'stk',200,false),
  ('haandsprit','haandsprit','Håndsprit','(håndsprit|hånddesinfektion|desinfektionsgel|hand sanitizer)',null,null,'l',0.5,true),
  ('saekke','saekke','Affaldsposer','(affaldsposer|affaldssække|skraldeposer|skraldesække|affaldspose)','(bio|mad|komposter)',null,'stk',30,false),
  ('kattegrus','kattegrus','Kattegrus','(kattegrus|kattestrøelse|kattesand)',null,null,'kg',5,false)
on conflict (key) do update set item = excluded.item, navn = excluded.navn, inc = excluded.inc, exc = excluded.exc,
  req = excluded.req, si = excluded.si, uge = excluded.uge, fast = excluded.fast;

drop function if exists public.nod_priser();
create or replace function public.nod_priser()
returns table (key text, kilde text, store text, heading text, price numeric, unit_price numeric, si text,
               pre_price numeric, valid_to date, offer_id text, lidl_unit numeric, uge numeric, fast boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.role() = 'authenticated' and not public.is_family() then raise exception 'ingen adgang'; end if;
  return query
  with b as (select coalesce((select array(select jsonb_array_elements_text(value)) from familie_indstilling where familie_indstilling.key = 'butikker'),
                             array['Lidl']) as stores),
  d as (select v.*, case when v.si in ('kg','l') then 'kg' else v.si end as sik from nod_vare v),
  l as (   -- Lidls faste pris
    select d.key, 'lidl'::text kilde, 'Lidl'::text store, s.heading, s.normal_price price,
           round(s.normal_price / s.qty_si, 2) unit_price, d.si, null::numeric pre_price, null::date valid_to, null::text offer_id
      from d join lidl_soeg s on lower(s.heading) ~ d.inc and (d.exc is null or lower(s.heading) !~ d.exc)
       and (d.req is null or lower(s.heading) ~ d.req)
       and s.normal_price is not null and s.qty_si > 0
       and (case when s.si_unit in ('kg','l') then 'kg' else s.si_unit end) = d.sik
  ),
  t as (   -- aktuelle tilbud i jeres butikker
    select d.key, 'tilbud'::text, o.store, o.heading, o.price, round(o.price / o.qty_si, 2), d.si, o.pre_price, o.valid_to, o.id
      from d join tjek_offers o on lower(o.heading) ~ d.inc and (d.exc is null or lower(o.heading) !~ d.exc)
       and (d.req is null or lower(o.heading || ' ' || coalesce(o.description, '')) ~ d.req)
       and o.valid_from <= current_date and o.valid_to >= current_date and o.qty_si > 0
       and (case when o.si_unit in ('kg','l') then 'kg' else o.si_unit end) = d.sik
      cross join b
     where o.store = any(b.stores)
       and public.familie_regel(o.heading || ' ' || coalesce(o.description, '')) is null
  ),
  a as (select * from l union all select * from t),
  lu as (select l.key, min(l.unit_price) u from l group by l.key)
  select distinct on (a.key) a.key, a.kilde, a.store, a.heading, a.price, a.unit_price, a.si, a.pre_price, a.valid_to, a.offer_id, lu.u, v.uge, v.fast
    from a left join lu on lu.key = a.key join nod_vare v on v.key = a.key
   order by a.key, a.unit_price, (a.kilde = 'lidl') desc, a.price;
end $$;
revoke all on function public.nod_priser() from public, anon;
grant execute on function public.nod_priser() to authenticated;

-- linje til "Værd at handle i dag" (tur.sql): gode tilbud på det, nødlageret mangler eller snart skal skifte.
-- Godt = mindst 10 % under Lidls faste pris pr. kg/l, eller (uden Lidl-pris) mindst 15 % under førprisen. Hvert tilbud nævnes kun én gang.
create table if not exists public.nod_tilbud_sendt (offer_id text primary key, sendt date not null default current_date);
alter table public.nod_tilbud_sendt enable row level security;
revoke all on public.nod_tilbud_sendt from anon, authenticated;

create or replace function public.nod_tilbud(out tekst text, out ids text[])
language plpgsql stable security definer set search_path = public as $$
declare v_uger int;
begin
  select coalesce((value #>> '{}')::int, 1) into v_uger from familie_indstilling where key = 'nodlager_uger';
  v_uger := coalesce(v_uger, 1);
  with p as (select * from nod_priser()),
  need as (
    select v.key, v.navn from nod_vare v
      left join nodlager n on n.key = v.item
     where n.key is null
        or (v.fast and n.uger = 0) or (not v.fast and n.uger < v_uger)
        or (n.udloeb is not null and n.udloeb <= current_date + n.varsel)
  ),
  good as (
    select need.navn, p.store, p.price, p.offer_id,
           row_number() over (order by coalesce(p.unit_price / nullif(p.lidl_unit, 0), p.price / nullif(p.pre_price, 0))) rn
      from need join p on p.key = need.key
     where p.kilde = 'tilbud'
       and ((p.lidl_unit is not null and p.unit_price <= p.lidl_unit * 0.9)
         or (p.lidl_unit is null and p.pre_price is not null and p.price <= p.pre_price * 0.85))
       and not exists (select 1 from nod_tilbud_sendt s where s.offer_id = p.offer_id)
  )
  select 'Nødlager: ' || string_agg(format('%s %s kr. i %s', lower(regexp_replace(g.navn, '\s*[(–].*$', '')),
                                            replace(replace(to_char(g.price, 'FM9990.00'), '.00', ''), '.', ','), g.store), ', ' order by g.rn) || '.',
         array_agg(g.offer_id)
    into tekst, ids from good g where g.rn <= 3;
end $$;
revoke all on function public.nod_tilbud() from public, anon, authenticated;
drop function if exists public.nod_tilbud_tekst();
