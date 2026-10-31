import { PGlite } from "@electric-sql/pglite"; import fs from "fs";
const db=new PGlite(); const ok=(c,m)=>console.log((c?"OK  ":"FEJL")+" "+m);
await db.exec(`create role anon; create role authenticated; create role service_role; create table catalog(key text primary key, data jsonb); create table offers(key text, store text, title text, size text, price numeric, ref_price numeric, valid_from date, valid_to date, note text);`);
await db.exec(fs.readFileSync(new URL('../../../familie_regler.sql', import.meta.url),'utf8'));
const R=async t=>(await db.query("select public.familie_regel($1) r",[t])).rows[0].r;
const cases=[
 ['Pålægsslagteren bacon i skiver','svinekød'],['3-STJERNET Landspegepølse','svinekød'],['Danish Crown hakket oksekød 8-12%','oksekød (kun fra Al-Rafiden)'],
 ['Hakket kalkun 7-10%',null],['Dulano kalkunsalami',null],['Salami','svinekød (ikke angivet)'],['Kyllingepølser',null],
 ['Haribo vingummi','slik med gelatine'],['Katjes vingummi vegan',null],['Skumbananer','slik med gelatine'],
 ['Gevalia kaffe 400 g','kaffe (kun Merrild Rød)'],['Merrild kaffe 400 g',null],['Merrild Rød 500 g',null],['Merrild Lys 400 g','kaffe (kun Merrild Rød)'],
 ['Kaffefiltre nr. 4',null],['Iskaffe latte',null],['Laktosefri creme fraiche',null],['Økologisk spinat',null],['Burgerbøf af kylling',null],['Hamburgerbøf','oksekød (kun fra Al-Rafiden)'],['Merrild eller Lavazza kaffe 340-500 g formalet kaffe eller 150 g Merrild gold instant kaffe',null],['Merrild instant kaffe 100 g','kaffe (kun Merrild Rød)'],['Rynkeby Nektar eller Blandet Bær bland selv drik',null],['Bland selv slik','slik med gelatine']];
for(const [t,want] of cases){const r=await R(t); ok(r===want,`${t} → ${r}`)}
await db.exec(`insert into catalog values ('kaffe','{"store":"Lidl"}'),('hakket okse','{"store":"Al-Rafiden Slagteri"}'),('x:slik','{"store":"Lidl"}')`);
const n=(await db.query(`select public.add_offers($1::jsonb) n`,[JSON.stringify([
 {key:'kaffe',store:'Netto',title:'Gevalia kaffe',price:30,ref_price:39,valid_to:'2099-01-01'},
 {key:'kaffe',store:'MENY',title:'Merrild kaffe 400 g',price:32,ref_price:39,valid_to:'2099-01-01'},
 {key:'hakket okse',store:'Netto',title:'Hakket oksekød',price:30,ref_price:60,valid_to:'2099-01-01'},
 {key:'x:slik',store:'Netto',title:'Haribo Matador mix',price:15,ref_price:25,valid_to:'2099-01-01'}])])).rows[0].n;
ok(n===1,'add_offers tager kun Merrild-tilbuddet: '+n);
