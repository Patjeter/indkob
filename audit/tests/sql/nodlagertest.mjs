// Nødlager (nodlager.sql): tabel, stempel ved ændring, kun familien (RLS), standardmål 1 uge
import { PGlite } from "@electric-sql/pglite";
import fs from "fs";
const db=new PGlite(); const ok=(c,m)=>console.log((c?"OK  ":"FEJL")+" "+m);
const q=async(s,p)=>(await db.query(s,p)).rows;
await db.exec(`create schema auth; create table me(e text); insert into me values ('besnik@x.dk');
create function auth.jwt() returns jsonb language sql as $$ select jsonb_build_object('email',(select e from me)) $$;
create role anon; create role authenticated; create publication supabase_realtime;
create function public.is_family() returns boolean language sql as $$ select (select e from me) in ('besnik@x.dk','valentina@x.dk') $$;
create table public.familie_indstilling(key text primary key, value jsonb not null);`);
const sql=fs.readFileSync(new URL('../../../nodlager.sql', import.meta.url),"utf8");
await db.exec(sql); await db.exec(sql);   // kan køres to gange
ok((await q("select value from familie_indstilling where key='nodlager_uger'"))[0].value===1,"mål 1 uge som standard");
await q("insert into nodlager(key,uger) values ('vand',1)");
ok((await q("select updated_by from nodlager"))[0].updated_by==='besnik@x.dk',"gemmer hvem");
await q("update me set e='valentina@x.dk'"); await q("update nodlager set uger=2 where key='vand'");
const r=(await q("select uger,updated_by from nodlager"))[0]; ok(r.uger===2&&r.updated_by==='valentina@x.dk',"ændring stemplet med Valentina");
let err=""; try{await q("insert into nodlager(key,uger) values ('x',3)")}catch(e){err=e.message} ok(/check/.test(err),"højst 2 uger");
ok((await q("select count(*)::int n from pg_publication_tables where tablename='nodlager'"))[0].n===1,"realtime slået til");
ok((await q("select count(*)::int n from pg_policies where tablename='nodlager' and policyname='kun familien'"))[0].n===1,"politik: kun familien");
