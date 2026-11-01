import { PGlite } from "@electric-sql/pglite";
import fs from "fs";
const db=new PGlite(); const ok=(c,m)=>console.log((c?"OK  ":"FEJL")+" "+m);
const q=async(s,p)=>(await db.query(s,p)).rows;
await db.exec(`create schema auth; create function auth.jwt() returns jsonb language sql as $$ select '{"email":"b@x"}'::jsonb $$;
create role anon; create role authenticated; create role service_role; create schema net; create function net.http_post(url text, headers jsonb, body jsonb) returns bigint language sql as $$ select 1::bigint $$;
create function public.is_family() returns boolean language sql as $$ select true $$;
create schema cron; create table cron.job(jobname text); create function cron.schedule(a text,b text,c text) returns int language sql as $$ select 1 $$; create function cron.unschedule(a text) returns boolean language sql as $$ select true $$;
create publication supabase_realtime;
create table cron_secret(id int, secret text);
create table push_subs(endpoint text primary key);
create table items(id text, key text, checked boolean default false, qty text);
create table catalog(key text primary key, data jsonb);
create table offers(id serial, key text, store text, title text, price numeric, ref_price numeric, valid_from date, valid_to date, source text);
create table lidl_alt(key text, normal_fam numeric);
create table kvit(tid text primary key, dato timestamptz, total numeric, parsed_total numeric);
create table dishes(id serial, name_da text, kind text, items jsonb);
create table kvit_linjer(tid text, nr int, navn text, antal numeric, beloeb numeric, key text);
create table nod_tilbud_sendt(offer_id text primary key, sendt date not null default current_date);
create table nod_stub(tekst text, ids text[]); insert into nod_stub values (null, null);
create function nod_tilbud(out tekst text, out ids text[]) language sql as $$ select tekst, ids from nod_stub $$;`);
await db.exec(fs.readFileSync(new URL('../../../tur.sql', import.meta.url),"utf8"));
await q(`insert into catalog values ('kaffe','{"da":"Kaffe","price":59,"every":14,"n":20,"last":"${new Date(Date.now()-12*864e5).toISOString().slice(0,10)}"}'),('maelk','{"da":"Mælk","price":13.5,"every":5,"n":50,"last":"${new Date().toISOString().slice(0,10)}"}'),('ost','{"da":"Ost","price":22,"every":30,"n":2}')`);
await q(`insert into items values ('1','maelk',false,'2')`);
const d=n=>new Date(Date.now()+n*864e5).toISOString().slice(0,10);
await q(`insert into offers(key,store,title,price,ref_price,valid_from,valid_to,source) values
 ('kaffe','Netto','Merrild 3-pak',115,177,'${d(-1)}','${d(3)}','auto'),
 ('maelk','Netto','Arla mælk',10,13.5,'${d(-1)}','${d(3)}','auto'),
 ('maelk','føtex','Mælk',5,13.5,'${d(-1)}','${d(3)}','auto'),
 ('ost','Netto','Ost',10,22,'${d(-1)}','${d(3)}','auto')`);
await q("update familie_indstilling set value='[\"Lidl\",\"Netto\"]' where key='butikker'"); let f=await q("select * from tur_forslag()"); ok(f.length===1&&f[0].store==='Netto'&&+f[0].n===2&&+f[0].spar===65.5,"kun Netto (føtex ikke valgt, ost ikke nødvendig): "+JSON.stringify(f));
let b=(await q("select public.tur_besked() b"))[0].b; ok(b&&/Netto sparer 66 kr\. på 2 varer, fx Merrild 3-pak 115,00 kr\.$/.test(b.body),"besked: "+JSON.stringify(b));
ok((await q("select public.tur_besked() b"))[0].b===null,"kun én besked om dagen");
await q("delete from offers where key='kaffe'"); await q("delete from tur_sendt");
ok((await q("select public.tur_besked() b"))[0].b===null,"under 40 kr.: ingen besked");
await q("insert into kvit values ('k1', now()-interval '2 days'),('k0', now()-interval '30 days')");
await q("insert into kvit_linjer values ('k1',1,'Blåbær 400g',1,52,'bloeber'),('k0',1,'Blåbær 125g',1,18,'bloeber')");
const s=await q("select * from seneste_pris"); ok(s.length===1&&s[0].navn==='Blåbær 400g'&&+s[0].pris===52,"seneste pris: "+JSON.stringify(s));

// v79: lagerpris, ret og mål
await q("delete from tur_sendt"); await q("delete from offers");
for(let i=0;i<6;i++){await q(`insert into kvit values ('h${i}', now()-interval '${20+i*30} days', 300, null)`); await q(`insert into kvit_linjer values ('h${i}',1,'Merrild 400g',1,${i==0?49:59},'kaffe')`);}
await q(`insert into offers(key,store,title,price,ref_price,valid_from,valid_to,source) values ('kaffe','Lidl','Merrild Rød 400 g',39,59,'${d(-1)}','${d(3)}','auto'),('maelk','Netto','Arla mælk',10,13.5,'${d(-1)}','${d(3)}','auto'),('agurk','Netto','Agurk',5,9,'${d(-1)}','${d(3)}','auto')`);
await q(`insert into catalog values ('agurk','{"da":"Agurk","price":9}') on conflict do nothing`);
await q(`insert into dishes(name_da,kind,items) values ('Salat med mælk','ret','[{"key":"maelk","qty":1},{"key":"agurk","qty":1}]'),('Kaffe-ret','madpakke','[{"key":"kaffe"}]')`);
const lf=await q("select * from lager_forslag()"); ok(lf.length===1&&lf[0].key==='kaffe'&&lf[0].pct===34,"lagerpris kaffe −34 %: "+JSON.stringify(lf));
const rf=await q("select * from ret_forslag()"); ok(rf.length===1&&rf[0].navn==='Salat med mælk'&&rf[0].paa_tilbud===2,"ret: "+JSON.stringify(rf));
b=(await q("select public.tur_besked() b"))[0].b; ok(b&&/^Lagerpris: Merrild Rød 400 g 39,00 kr\. i Lidl \(−34 %\)/.test(b.body)&&/Ret: Salat med mælk/.test(b.body),"besked uden tur, med lager og ret: "+(b&&b.body));
await q("insert into kvit values ('m1', now(), 1200, null)");
const ms=(await q("select public.maal_status() m"))[0].m; ok(ms.maal==5050&&ms.brugt>=1200,"mål: "+JSON.stringify(ms));
const fk=await q("select * from forbrug_kat"); ok(fk.length>0,"forbrug_kat: "+fk.length);

// v82: nødlager-tilbud i turbeskeden – også alene, og hvert tilbud kun én gang
await q("delete from tur_sendt"); await q("delete from offers");
await q("update nod_stub set tekst='Nødlager: hakkede tomater 6 kr. i Netto.', ids=array['o1']");
b=(await q("select public.tur_besked() b"))[0].b; ok(b&&b.body==='Nødlager: hakkede tomater 6 kr. i Netto.',"nødlager alene giver besked: "+JSON.stringify(b));
ok((await q("select offer_id from nod_tilbud_sendt"))[0].offer_id==='o1',"tilbuddet huskes som sendt");
