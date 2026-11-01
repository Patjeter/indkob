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
create table public.cron_secret(id int, secret text);
create function auth.role() returns text language sql as $$ select 'authenticated' $$;
create function public.familie_regel(t text) returns text language sql as $$ select case when t ~* 'svin' then 'svin' end $$;
create table public.lidl_soeg(heading text, normal_price numeric, qty_si numeric, si_unit text);
create table public.tjek_offers(id text primary key, store text, heading text, description text, price numeric, pre_price numeric, qty_si numeric, si_unit text, valid_from date, valid_to date);`);
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

// billigste pris (v82)
await q("insert into familie_indstilling values ('butikker','[\"Lidl\",\"Netto\"]')");
await q(`insert into lidl_soeg values ('COMBINO Spaghetti',8.95,1,'kg'),('Hakkede tomater',7.95,0.4,'kg'),('FRESHONA Søde majs',8.95,0.45,'kg'),('Pastasauce',20,0.5,'kg')`);
const dd=n=>new Date(Date.now()+n*864e5).toISOString().slice(0,10);
await q(`insert into tjek_offers values
 ('o1','Netto','ØGO hakkede tomater',null,6,9,0.4,'kg','${dd(-1)}','${dd(3)}'),
 ('o2','føtex','Hakkede tomater',null,3,9,0.4,'kg','${dd(-1)}','${dd(3)}'),
 ('o3','Netto','Spaghetti',null,9.5,null,1,'kg','${dd(-1)}','${dd(3)}'),
 ('o4','Netto','Kikærter med svinekød',null,1,5,0.4,'kg','${dd(-1)}','${dd(3)}'),
 ('o5','Netto','Kikærter',null,6,9,0.25,'kg','${dd(5)}','${dd(9)}')`);
const pr=Object.fromEntries((await q("select * from nod_priser()")).map(r=>[r.key,r]));
ok(pr.tomat&&pr.tomat.store==='Netto'&&+pr.tomat.price===6&&+pr.tomat.lidl_unit===19.88,"tomater: Netto 6 kr. (føtex ikke jeres butik): "+JSON.stringify(pr.tomat));
ok(pr.pasta&&pr.pasta.kilde==='lidl'&&+pr.pasta.price===8.95,"pasta: Lidls faste pris er billigst");
ok(!pr.boenner,"ingen kikærter: svin afvist, fremtidigt tilbud tælles ikke");
ok(!pr.groent||pr.groent.kilde==='lidl',"majs fra Lidl");
let nt=(await q("select * from nod_tilbud()"))[0];
ok(nt.tekst==='Nødlager: hakkede tomater og passata 6 kr. i Netto.'&&nt.ids.join()==='o1',"turlinje: "+nt.tekst);
await q("insert into nodlager(key,uger) values ('tomat',2) on conflict (key) do update set uger=2, udloeb=null");
ok((await q("select * from nod_tilbud()"))[0].tekst===null,"har tomater nok: ingen linje");
await q("update nodlager set udloeb=current_date+5 where key='tomat'");
ok(/tomater/.test((await q("select * from nod_tilbud()"))[0].tekst||''),"tomater skal snart skiftes: med igen");
await q("insert into nod_tilbud_sendt values ('o1')");
ok((await q("select * from nod_tilbud()"))[0].tekst===null,"samme tilbud nævnes kun én gang");
