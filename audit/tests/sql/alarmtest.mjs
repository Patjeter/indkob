import { PGlite } from "@electric-sql/pglite";
import fs from "fs";
const db=new PGlite(); const ok=(c,m)=>console.log((c?"OK  ":"FEJL")+" "+m);
const q=async(s,p)=>(await db.query(s,p)).rows;
await db.exec(`create schema auth; create function auth.jwt() returns jsonb language sql as $$ select '{"email":"b@x"}'::jsonb $$; create function auth.role() returns text language sql as $$ select null::text $$;
create role anon; create role authenticated; create role service_role; create schema net; create function net.http_post(url text, headers jsonb, body jsonb) returns bigint language sql as $$ select 1::bigint $$;
create function public.is_family() returns boolean language sql as $$ select true $$;
create schema cron; create table cron.job(jobname text); create function cron.schedule(a text,b text,c text) returns int language sql as $$ select 1 $$; create function cron.unschedule(a text) returns boolean language sql as $$ select true $$;
create table watch(key text primary key, ref_qty numeric, active boolean default true);
create table offer_test(key text, offer_id text, store text, heading text, price numeric, offer_unit numeric, valid_from date, valid_to date, status text, reason text);`);
await db.exec(fs.readFileSync(new URL('../../../prisalarm.sql', import.meta.url),"utf8"));
await q(`insert into watch values ('kaffe',0.5,true)`);
await q(`insert into prisalarm(key,name_da,max_price) values ('kaffe','Kaffe',40),('x:fløde','Fløde',10)`);
await q(`insert into offer_test values
 ('kaffe','o1','Netto','Merrild 400 g',28,70,current_date,current_date+5,'afvist','ikke billigere'),
 ('kaffe','o2','REMA 1000','Merrild 500 g',42,84,current_date,current_date+5,'kandidat',null),
 ('kaffe','o3','føtex','Merrild 400 g',20,50,current_date,current_date+5,'afvist','svinekød'),
 ('kaffe','o4','MENY','Merrild 500 g',30,60,current_date-9,current_date-1,'valgt',null)`);
let r=(await q("select public.prisalarm_scan() r"))[0].r;
ok(r.nye===1,"1 fund (Netto 70 kr./kg × 0,5 = 35 ≤ 40; REMA 42 > 40; føtex afvist; MENY udløbet): "+JSON.stringify(r));
ok(JSON.stringify(r.uden_overvaagning)==='["x:fløde"]',"fløde er ikke overvåget");
const h=await q("select * from prisalarm_hit"); ok(+h[0].eq_price===35&&+h[0].price===28&&h[0].store==='Netto',"pris for jeres pakke 35, tilbudspris 28");
r=(await q("select public.prisalarm_scan() r"))[0].r; ok(r.nye===0,"samme tilbud findes ikke igen");
const c=await q("select * from prisalarm_claim()"); ok(c.length===1&&c[0].email==='b@x'&&+c[0].max_price===40,"claim giver alarm + e-mail");
ok((await q("select * from prisalarm_claim()")).length===0,"ingen dobbeltbesked");
await q("delete from prisalarm where key='kaffe'"); ok((await q("select count(*)::int n from prisalarm_hit"))[0].n===0,"slet alarm fjerner fund");
