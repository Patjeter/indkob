// Nødlager (nodlager.sql): tabel, stempel ved ændring, kun familien (RLS), standardmål 1 uge
import { PGlite } from "@electric-sql/pglite";
import fs from "fs";
const db=new PGlite(); const ok=(c,m)=>console.log((c?"OK  ":"FEJL")+" "+m);
const q=async(s,p)=>(await db.query(s,p)).rows;
await db.exec(`create schema auth; create table me(e text); insert into me values ('besnik@x.dk');
create function auth.jwt() returns jsonb language sql as $$ select jsonb_build_object('email',(select e from me)) $$;
create role anon; create role authenticated; create publication supabase_realtime;
create function public.is_family() returns boolean language sql as $$ select (select e from me) in ('besnik@x.dk','valentina@x.dk') $$;
create table public.familie_indstilling(key text primary key, value jsonb not null);
create schema cron; create table cron.job(jobname text, schedule text, command text);
create function cron.schedule(n text, s text, c text) returns int language sql as $$ insert into cron.job values (n,s,c); select 1 $$;
create function cron.unschedule(n text) returns boolean language sql as $$ delete from cron.job where jobname=n; select true $$;
create table public.cron_secret(id int, secret text);`);
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

// holdbarhed og besked (v81)
await q("update me set e='besnik@x.dk'");
await q("insert into nodlager(key,uger,navn,navn_sq,udloeb,varsel) values ('fisk',1,'Fisk på dåse (tun, makrel)','Peshk në kanaçe (ton)',current_date+10,30),('pasta',1,'Pasta, ris og couscous','Makarona',current_date+200,30),('powerbank',1,'Powerbanks, opladte','Powerbank',current_date+5,0),('jod',0,'Jodtabletter','Tableta jodi',current_date-1,30)");
const before=(await q("select updated_at from nodlager where key='fisk'"))[0].updated_at;
let m=(await q("select public.nod_varsel() m"))[0].m;
ok(m&&/^Fisk på dåse \(\d+\/\d+\) – brug det/.test(m.da.body)&&!/Pasta|Powerbank|Jod/.test(m.da.body),"besked om fisk (kort navn), ikke pasta/powerbank/jod (uger 0): "+(m&&m.da.body));
ok(m&&/^Peshk në kanaçe \(/.test(m.sq.body)&&/Rezerva/.test(m.sq.title),"albansk tekst: "+(m&&m.sq.body));
ok((await q("select public.nod_varsel() m"))[0].m===null,"samme dato advares kun én gang");
ok(String((await q("select updated_at from nodlager where key='fisk'"))[0].updated_at)===String(before),"advarslen ændrer ikke 'sidst ændret'");
await q("update nodlager set udloeb=current_date+20 where key='fisk'");
ok(/Fisk/.test((await q("select public.nod_varsel() m"))[0].m.da.body),"ny dato: advares igen");
await q("update nodlager set udloeb=current_date where key='powerbank'");
ok(/Powerbanks, opladte \(/.test((await q("select public.nod_varsel() m"))[0].m.da.body),"powerbank på dagen (varsel 0)");
ok((await q("select count(*)::int n from cron.job where jobname='indkob-nodlager' and command like '%nod_varsel%'"))[0].n===1,"daglig kørsel planlagt");
