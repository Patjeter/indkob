-- Sammenlign: alle aktuelle og kommende tilbud på én af familiens varer, på tværs af kæder.
-- Kun tilbud, hvor varen, enheden og størrelsen passer (samme regler som automatikken, intet svinekød).
create or replace function public.tilbud_for(k text)
returns table (store text, heading text, price numeric, pre_price numeric, size text, offer_unit numeric, si_unit text,
               eq_price numeric, maks int, valid_from date, valid_to date, valgt boolean)
language sql stable security definer set search_path = public as $$
  select t.store, t.heading, t.price, t.pre_price, t.size, t.offer_unit, o.si_unit,
         round(coalesce(t.offer_unit * w.ref_qty, t.price), 2),
         nullif(substring(coalesce(o.description,'') from '(?i)maks\.?\s*(\d+)'), '')::int,
         t.valid_from, t.valid_to, t.status = 'valgt'
    from offer_test t
    join watch w on w.key = t.key
    left join tjek_offers o on o.id = t.offer_id
   where public.is_family() and t.key = k and t.valid_to >= current_date
     and (t.status in ('kandidat','valgt') or t.reason in ('ikke billigere','under 1,50 kr. sparet'))
   order by t.offer_unit nulls last, t.valid_from
   limit 12
$$;
revoke all on function public.tilbud_for(text) from public, anon;
grant execute on function public.tilbud_for(text) to authenticated;
