import { PGlite } from "@electric-sql/pglite";
import fs from "fs";
const db=new PGlite(); const ok=(c,m)=>console.log((c?"OK  ":"FEJL")+" "+m);
const q=async(s,p)=>(await db.query(s,p)).rows;
await db.exec(`create schema auth; create function auth.jwt() returns jsonb language sql as $$ select '{}'::jsonb $$;
create role anon; create role authenticated; create role service_role; create schema extensions; create schema net;
create function public.is_family() returns boolean language sql as $$ select true $$;
create schema cron; create table cron.job(jobname text); create function cron.schedule(a text,b text,c text) returns int language sql as $$ select 1 $$; create function cron.unschedule(a text) returns boolean language sql as $$ select true $$;
create table catalog(key text primary key, data jsonb); create table bought(id serial, key text, at timestamptz); create table items(id serial, key text, checked boolean default false);
create table offers (id bigint generated always as identity primary key, key text not null, store text not null, title text, size text, price numeric not null, ref_price numeric, valid_from date, valid_to date not null, note text, created_at timestamptz not null default now());`);
await db.exec(fs.readFileSync(new URL('../../../familie_regler.sql', import.meta.url),"utf8"));
await db.exec(fs.readFileSync(new URL('../../../tilbud_auto.sql', import.meta.url),"utf8").split("-- 4) Match")[0]);  // tabeller
await db.exec(fs.readFileSync(new URL('../../../lidl_priser.sql', import.meta.url),"utf8").replace(/create or replace function public.lidl_fetch[\s\S]*?end \$\$;/,'').replace(/create or replace function public.lidl_process[\s\S]*?end \$\$;/,'').replace(/revoke all on function public.lidl_fetch\(\), public.lidl_process\(\)[^;]*;/,''));
await db.exec(fs.readFileSync(new URL('../../../tilbud_auto.sql', import.meta.url),"utf8"));
await q(`insert into watch(key,name,cat,n,inc,exc,ref_price,ref_qty,ref_si,usual) values
 ('smoer','Smør','mk',18,'smør|smørbar','kage',19.95,0.2,'kg',2),
 ('maelk','Sødmælk','mk',51,'sødmælk','laktosefri',13.5,1,'l',2)`);
await q(`insert into catalog values ('smoer','{"prod":["Lurpak Smørbar"]}'),('maelk','{"prod":["MADVÆRKET Sødmælk"]}')`);
const rows=[
 {id:'a',pkey:'lurpak smør eller smørbar|200g',heading:'LURPAK Smør eller smørbar',brand:'LURPAK',own:false,size_from:200,size_to:200,unit:'g',qty_si:0.2,si_unit:'kg',price:19.95,pre_price:null,fast:true,valid_from:'2026-05-02',valid_to:'2026-12-31'},
 {id:'b',pkey:'milbona letsaltet smør eller smørbar|200g',heading:'MILBONA Letsaltet smør eller smørbar',brand:'MILBONA',own:true,size_from:200,size_to:200,unit:'g',qty_si:0.2,si_unit:'kg',price:9.95,pre_price:null,fast:true,valid_from:'2026-05-02',valid_to:'2026-12-31'},
 {id:'c',pkey:'madværket sødmælk|1l',heading:'MADVÆRKET Sødmælk',brand:'MADVÆRKET',own:true,size_from:1,size_to:1,unit:'l',qty_si:1,si_unit:'l',price:11.95,pre_price:null,fast:true,valid_from:'2026-05-02',valid_to:'2026-12-31'},
 {id:'d',pkey:'pålægsslagteren bacon|150g',heading:'PÅLÆGSSLAGTEREN Bacon i skiver',brand:'PÅLÆGSSLAGTEREN',own:false,size_from:150,size_to:150,unit:'g',qty_si:0.15,si_unit:'kg',price:19.95,pre_price:null,fast:true,valid_from:'2026-05-02',valid_to:'2026-12-31'}];
await q("select public.lidl_ingest($1::jsonb)",[JSON.stringify(rows)]);
const r=(await q("select public.lidl_alt_refresh() r"))[0].r; console.log(JSON.stringify(r));
const a=await q("select * from lidl_alt order by key"); a.forEach(x=>console.log('   ',x.key,x.normal_heading,x.normal_fam,'| eget:',x.own_heading,x.own_price,x.own_save));
const g=k=>a.find(x=>x.key===k);
ok(g('smoer').normal_heading.startsWith('LURPAK')&&+g('smoer').normal_fam===19.95,"smør: jeres Lurpak hos Lidl 19,95");
ok(g('smoer').own_heading.startsWith('MILBONA')&&+g('smoer').own_save===10,"smør: Lidls eget Milbona, spar 10 kr.");
ok(g('maelk').normal_heading.startsWith('MADV')&&g('maelk').own_heading===null,"mælk: I køber allerede Lidls eget → intet alternativ");
// match bruger Lidls normalpris
await q(`insert into tjek_offers(id,store,heading,price,qty_si,si_unit,size_from,unit,valid_from,valid_to) values ('x','Netto','Sødmælk',12.5,1,'l',1,'l',current_date,current_date+3)`);
await q("select public.match_offers_test()"); const t=await q("select status,reason,ref_unit from offer_test where key='maelk'");
ok(+t[0].ref_unit===11.95&&t[0].reason==='ikke billigere',"Netto-mælk 12,50 er IKKE billigere end Lidls 11,95 (før: kvitteringspris 13,50): "+JSON.stringify(t[0]));
// v71: fælles regler og øko til samme pris
await q(`insert into watch(key,name,cat,n,inc,exc,ref_price,ref_qty,ref_si,usual) values ('x:paalaeg','Kyllingepålæg','km',7,'pålæg',null,15,0.1,'kg',1)`);
await q(`insert into tjek_offers(id,store,heading,price,qty_si,si_unit,size_from,unit,valid_from,valid_to) values ('y','Netto','Skinke pålæg',8,0.1,'kg',100,'g',current_date,current_date+3),('z','Netto','Kylling pålæg',9,0.1,'kg',100,'g',current_date,current_date+3)`);
await q("select public.match_offers_test()");
const pa=await q("select heading,status,reason from offer_test where key='x:paalaeg' order by heading");
ok(pa.find(x=>x.heading==='Skinke pålæg').reason==='svinekød'&&pa.find(x=>x.heading==='Kylling pålæg').status!=='afvist','tilbud: skinke afvist, kylling ok: '+JSON.stringify(pa));
await q("select public.lidl_ingest($1::jsonb)",[JSON.stringify([{id:'e',pkey:'madværket økologisk sødmælk|1l',heading:'MADVÆRKET Økologisk sødmælk',brand:'MADVÆRKET',own:true,size_from:1,size_to:1,unit:'l',qty_si:1,si_unit:'l',price:12.45,pre_price:null,fast:true,valid_from:'2026-05-02',valid_to:'2026-12-31'},
 {id:'g',pkey:'gevalia kaffe|400g',heading:'GEVALIA Kaffe',brand:'GEVALIA',own:false,size_from:400,size_to:400,unit:'g',qty_si:0.4,si_unit:'kg',price:35,pre_price:null,fast:true,valid_from:'2026-05-02',valid_to:'2026-12-31'}])]);
await q("select public.lidl_alt_refresh()");
const m=(await q("select eco_heading, eco_extra from lidl_alt where key='maelk'"))[0];
ok(m&&m.eco_heading==='MADVÆRKET Økologisk sødmælk'&&+m.eco_extra<=2,'øko til samme pris for mælk: '+JSON.stringify(m));
await db.exec(fs.readFileSync(new URL('../../../lidl_soeg.sql', import.meta.url),"utf8"));
const sg=(await q("select heading from lidl_soeg")).map(x=>x.heading);
ok(!sg.some(h=>/GEVALIA|bacon/i.test(h))&&sg.some(h=>/Økologisk sødmælk/.test(h)),'Lidl-søgning: ingen Gevalia eller bacon: '+sg.join(', '));
