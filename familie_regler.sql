-- Familiens faste regler samlet ét sted (v71). Bruges af tilbudsmatchningen, Lidl-søgningen,
-- Lidl-alternativerne og add_offers, så reglerne ikke kan glide fra hinanden.
-- Returnerer null, når teksten er i orden, ellers grunden til at varen ikke må foreslås.
create or replace function public.familie_regel(tekst text) returns text
language sql immutable set search_path = public as $$
  with t as (select ' ' || lower(translate(coalesce(tekst, ''), 'ÆØÅÄÖÜÉ', 'æøåäöüé')) || ' ' as x)
  select case
    -- aldrig svinekød
    when x ~ '(svin|skinke|bacon|flæsk|medister|rullepølse|hamburgerryg|kamsteg|nakkefilet|nakkekotelet|ribbensteg|spareribs|pepperoni|serrano|prosciutto|chorizo|leverpostej|frikadelle|wienerpølse|grillpølse|hotdogpølse|spegepølse|mortadella|kassler|pulled pork|porchetta|[^a-zæøåäöüé]gris[^a-zæøåäöüé])'
      then 'svinekød'
    when x ~ '(pølse|salami|postej|paté|pate|frankfurter|pålæg)'
     and x !~ '(kylling|kalkun|fjerkræ|fisk|laks|tun|reje|vegansk|vegetar|plantebaseret|veggie)'
      then 'svinekød (ikke angivet)'
    -- oksekød kun fra Al-Rafiden Slagteri
    when x ~ '(okse|kalv|entrecote|rumpsteak|ribeye|tournedos|culotte|flanksteak|cevapcici|roastbeef|pastrami|angus|wagyu)'
      then 'oksekød (kun fra Al-Rafiden)'
    when x ~ '(hakket kød|hakkebøf|burgerbøf|hamburgerbøf)'
     and x !~ '(kalkun|kylling|fjerkræ|vegansk|vegetar|plantebaseret|veggie)'
      then 'oksekød (kun fra Al-Rafiden)'
    -- slik kun uden svinegelatine
    when x ~ '(vingummi|bland.?selv|jelly beans|lakrids|skumfidus|skumbanan|marshmallow|haribo|malaco|matador|winegum|[^a-zæøåäöüé]slik[^a-zæøåäöüé])'
     and x !~ '(vegan|veggie|gelatinefri|uden gelatine|katjes|halal)'
      then 'slik med gelatine'
    -- kaffe kun Merrild Rød
    when x ~ '([^a-zæøåäöüé]kaffe[^a-zæøåäöüé]|kaffebønner|filterkaffe|formalet kaffe|hele bønner)'
     and x !~ 'merrild'
      then 'kaffe (kun Merrild Rød)'
    when x ~ 'merrild' and x ~ '(lys|mørk|espresso|instant|kapsl|pods|decaf|koffeinfri)' and x !~ 'rød'
      then 'kaffe (kun Merrild Rød)'
    else null end
  from t
$$;
grant execute on function public.familie_regel(text) to authenticated, service_role;
revoke execute on function public.familie_regel(text) from anon, public;

-- tilbud fra den faste opgave skal også overholde reglerne; okse-varer købes kun hos slagteren
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
      and exists (select 1 from public.catalog c where c.key = x->>'key' and coalesce(c.data->>'store','') <> 'Al-Rafiden Slagteri')
      and public.familie_regel(x->>'title') is null
      and not exists (select 1 from public.offers o where o.key = x->>'key' and o.store = x->>'store' and o.valid_to = (x->>'valid_to')::date)
    returning 1)
  select count(*)::int from ins
$fn$;
revoke all on function public.add_offers(jsonb) from public, anon, authenticated;
