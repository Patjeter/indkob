-- v50: Lidls sortiment kan søges i appen
-- Visning over prisregistret (lidl_products) med familiens faste regler fra familie_regel() (familie_regler.sql)
--   og uden non-food (værktøj, tøj, blomster …),
--   og kun varer med en pris, der gælder nu (fast pris / førpris, eller et tilbud der ikke er udløbet).
-- security_invoker: RLS på lidl_products gælder stadig ("kun familien").
-- Kør i Supabase → SQL Editor.

create or replace view public.lidl_soeg with (security_invoker = true) as
with p as (
  select lp.*, lower(translate(lp.heading, 'ÆØÅÄÖÜÉ', 'æøåäöüé')) as hl,
         -- en "tilbudspris", der gælder i over 35 dage (Lidls lange katalog maj–dec.), er reelt en fast pris
         (lp.offer_price is not null and lp.offer_to >= current_date and lp.offer_to - coalesce(lp.offer_from, lp.first_seen) > 35) as lang
    from public.lidl_products lp
), q as (
  select p.*,
         case when offer_price is not null and offer_to >= current_date and not lang and (offer_from is null or offer_from <= current_date + 3)
              then offer_price end as tilbud,
         coalesce(normal_price, case when lang then offer_price end) as fast
    from p
)
select pkey, heading, brand, own_brand, size_from, unit, qty_si, si_unit,
       fast as normal_price, case when normal_price is not null then normal_kind when lang then 'fast' end as normal_kind,
       tilbud as offer_price, case when tilbud is not null then offer_from end as offer_from, case when tilbud is not null then offer_to end as offer_to,
       coalesce(tilbud, fast) as price,
       case when qty_si > 0 then round(coalesce(tilbud, fast) / qty_si, 2) end as unit_price,
       last_seen
  from q
 where coalesce(tilbud, fast) is not null
   and last_seen >= current_date - 120
   -- non-food
   and coalesce(upper(brand), '') !~ '^(SILVERCREST|PARKSIDE|LIVARNO|LUPILU|CRIVIT|ESMARA|LIVERGY|PEPPERTS|MELINERA|AURIOL|ERNESTO|POWERFIX|ULTIMATE SPEED|MIOMARE|TRONIC|ZOOFARI)'
   and hl !~ '(brændende kærlighed|flamingoblomst|krysantemum|lyng|lilje|orkidé|potteplante|plantebeskyttelse|knæpude|julestjerne|tulipan|buket|skriveartik|julekalenderbog|møllehjul)'
   and not (brand is null and hl ~ '^roser?$')
   -- familiens faste regler (svinekød, oksekød, gelatine, kaffe) – samme kontrol som tilbuddene
   and public.familie_regel(heading) is null;

revoke all on public.lidl_soeg from anon;
grant select on public.lidl_soeg to authenticated;
