-- Oprydning i rettigheder (13. okt. 2026). Supabase giver som standard flere rettigheder end appen bruger.
-- TRUNCATE går uden om række-sikkerhed, så den fjernes helt; visninger og fund-tabellen må kun læses.
do $$ declare r record; begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind in ('r','v') loop
    execute format('revoke truncate, references, trigger on public.%I from anon, authenticated', r.relname);
  end loop;
end $$;
revoke all on public.kvit_status from anon, public;
revoke insert, update, delete on public.prisalarm_hit, public.lidl_soeg, public.kvit_status from authenticated;
revoke execute on function public.kvit_clean(text), public.kvit_key(text, numeric) from anon, public;
-- publish_offers() er kun til den daglige automatik (pg_cron), ikke til appen
revoke execute on function public.publish_offers() from authenticated;
