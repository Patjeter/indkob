-- Ugens analyse: ét samlet, læsbart udtræk til den ugentlige gennemgang (planlagt opgave).
-- Kun læsning. Køres som: select public.ugeanalyse();
create or replace function public.ugeanalyse(dage int default 7) returns jsonb
language sql stable security invoker set search_path = public as $$
with
  k  as (select * from kvit where dato >= now() - make_interval(days => dage)),
  k4 as (select * from kvit where dato >= now() - make_interval(days => 28 + dage) and dato < now() - make_interval(days => dage)),
  l  as (select kl.*, k.kaede, k.ejer from kvit_linjer kl join k using (tid)),
  navn as (select data->>'key' as key, data->>'da' as da, (data->>'n')::int as n, (data->>'every')::int as every, data->>'last' as last from catalog)
select jsonb_build_object(
  'periode', jsonb_build_object('fra', (now() - make_interval(days => dage))::date, 'til', now()::date, 'dage', dage),
  'kvitteringer', (select jsonb_build_object('antal', count(*), 'kr', round(coalesce(sum(total),0)),
      'pr_kaede', (select jsonb_object_agg(kaede, kr) from (select coalesce(kaede,'?') kaede, round(sum(total)) kr from k group by 1) x),
      'pr_ejer',  (select jsonb_object_agg(ejer, n) from (select coalesce(ejer,'?') ejer, count(*) n from k group by 1) x)) from k),
  'snit_pr_uge_de_4_uger_foer', (select round(coalesce(sum(total),0) / 4.0 * dage / 7) from k4),
  'mest_koebt', (select jsonb_agg(x) from (
      select coalesce(n.da, l.key) vare, round(sum(coalesce(l.antal,1))) stk, round(sum(l.beloeb)) kr
        from l left join navn n using (key) where l.key is not null and l.key <> '-'
       group by 1 order by 3 desc limit 15) x),
  'ukendte_kvitteringsnavne', (select jsonb_agg(x) from (
      select navn, count(*) gange, round(sum(beloeb)) kr from l where key is null group by 1 order by 3 desc limit 15) x),
  'lidls_eget_kunne_spare', (select jsonb_agg(x) from (
      select coalesce(n.da, a.key) vare, a.normal_heading jeres, a.own_heading lidls_eget, a.own_save spar_pr_koeb,
             round(a.own_save * 365.0 / greatest(n.every, 3)) spar_pr_aar
        from lidl_alt a join navn n using (key)
       where a.own_save >= 2 and n.n >= 5 order by 5 desc limit 10) x),
  'appen', jsonb_build_object(
      'varer_tilfoejet', (select count(*) from items where created_at >= now() - make_interval(days => dage)),
      'tilfoejet_af', (select jsonb_object_agg(coalesce(added_by,'?'), n) from (select added_by, count(*) n from items where created_at >= now() - make_interval(days => dage) group by 1) x),
      'krydset_af_i_butik', (select jsonb_object_agg(store, n) from (select coalesce(store,'Lidl') store, count(*) n from bought where at >= now() - make_interval(days => dage) and item_id is not null group by 1) x),
      'aabne_varer_nu', (select count(*) from items where not checked)),
  'tilbud_brugt_udenfor_lidl', (select jsonb_agg(x) from (
      select b.name_da vare, b.store, b.price from bought b where b.at >= now() - make_interval(days => dage) and coalesce(b.store,'Lidl') <> 'Lidl' order by b.at limit 20) x),
  'tilbud_lige_nu', (select count(*) from offers where valid_to >= current_date),
  'forfaldne_varer_ikke_paa_listen', (select jsonb_agg(x) from (
      select n.da vare, n.every hver_dag, current_date - greatest(n.last::date, (select max(at)::date from bought b where b.key = n.key)) dage_siden
        from navn n
       where n.every between 2 and 60 and n.n >= 6 and n.last is not null
         and current_date - greatest(n.last::date, (select max(at)::date from bought b where b.key = n.key)) > n.every * 1.5
         and not exists (select 1 from items i where i.key = n.key and not i.checked)
       order by 3 desc limit 10) x),
  'prisalarmer', (select jsonb_agg(x) from (
      select a.name_da vare, a.max_price, exists (select 1 from watch w where w.key = a.key and w.active) overvaaget,
             (select count(*) from prisalarm_hit h where h.alarm_id = a.id and h.valid_to >= current_date) fund_nu
        from prisalarm a where a.active) x)
)
$$;
revoke all on function public.ugeanalyse(int) from public, anon, authenticated;
