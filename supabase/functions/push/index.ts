// Edge Function "push": sender én samlet notifikation, når nogen har tilføjet varer til indkøbslisten,
// og prisalarmer, når en vare er på tilbud under familiens egen grænse.
// Kaldes hvert minut af pg_cron (se push.sql), men kun når der er varer, der venter,
// og hver morgen med {"alarm":true} (se prisalarm.sql), når der er nye fund.
// Hemmelighed: VAPID_PRIVATE_KEY (Edge Functions → Secrets). SUPABASE_URL og SUPABASE_SERVICE_ROLE_KEY sætter Supabase selv.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const VAPID_PUBLIC = "BAQzM0ubxlqV9ILhQMADiuODUmq0n05taW0d26FW0eV13qHUgqLmTwiOZCwSYyZmcb0YWBuKsG-oy-YoMu8bPdA";
const APP = "https://patjeter.github.io/indkob/";
const MAX_NAMES = 6;

type Item = { id: string; text: string; name_da: string | null; name_sq: string | null; checked: boolean; added_dev: string | null; added_by: string | null };
type Sub = { endpoint: string; p256dh: string; auth: string; dev: string; lang: string; email: string | null };

const TXT = {
  da: { who: (n: string, c: number) => `${n} tilføjede ${c} ${c === 1 ? "vare" : "varer"}`,
        anon: (c: number) => c === 1 ? "1 ny vare på listen" : `${c} nye varer på listen`,
        more: (c: number) => `+ ${c} mere` },
  sq: { who: (n: string, c: number) => `${n} shtoi ${c} ${c === 1 ? "artikull" : "artikuj"}`,
        anon: (c: number) => c === 1 ? "1 artikull i ri në listë" : `${c} artikuj të rinj në listë`,
        more: (c: number) => `+ ${c} të tjera` },
};

type Hit = { alarm_id?: string; offer_id?: string; email: string | null; key: string; name_da: string | null; name_sq: string | null; max_price: number;
  store: string; heading: string | null; price: number; eq_price: number; valid_to: string };

const kr = (n: number) => (Math.round(Number(n) * 100) / 100).toLocaleString("da-DK", { minimumFractionDigits: Number(n) % 1 ? 2 : 0, maximumFractionDigits: 2 }) + " kr.";
const dm = (d: string) => { const [, m, dd] = String(d).slice(0, 10).split("-"); return `${+dd}/${+m}`; };

/** Ren funktion (testes lokalt): prisalarmer → én besked pr. alarm og telefon, med det billigste fund */
export function planAlarms(hits: Hit[], subs: Sub[]) {
  const low = (s: string | null) => (s || "").toLowerCase();
  const best = new Map<string, { h: Hit; n: number }>();
  for (const h of hits) {
    const k = h.key + "|" + low(h.email), b = best.get(k);
    if (!b) best.set(k, { h, n: 1 });
    else { b.n++; if (Number(h.eq_price) < Number(b.h.eq_price)) b.h = h; }
  }
  const out: { sub: Sub; title: string; body: string; n: number }[] = [];
  for (const { h, n } of best.values()) {
    for (const s of subs) {
      if (h.email && low(s.email) !== low(h.email)) continue;      // kun til den, der satte alarmen
      const sq = s.lang === "sq", name = sq ? (h.name_sq || h.name_da || h.key) : (h.name_da || h.key);
      const pack = Number(h.eq_price) !== Number(h.price) ? (sq ? ` (${kr(h.price)} në ofertë)` : ` (tilbudspris ${kr(h.price)})`) : "";
      const more = n > 1 ? (sq ? ` · ${n - 1} oferta të tjera` : ` · ${n - 1} tilbud mere`) : "";
      out.push({ sub: s, n: 1,
        title: sq ? `Alarm çmimi: ${name}` : `Prisalarm: ${name}`,
        body: sq ? `${h.store}: ${kr(h.eq_price)}${pack}, nën kufirin ${kr(h.max_price)} Vlen deri më ${dm(h.valid_to)}${more}.`
                 : `${h.store}: ${kr(h.eq_price)}${pack}, under jeres grænse på ${kr(h.max_price)} Gælder til ${dm(h.valid_to)}${more}.` });
    }
  }
  return out;
}

/** Ren funktion (testes lokalt): hvilke beskeder skal sendes til hvilke telefoner */
export function plan(claimed: Item[], subs: Sub[], family: { email: string; name: string | null }[]) {
  const several = family.length > 1, low = (s: string | null) => (s || "").toLowerCase();
  const groups = new Map<string, Item[]>();
  for (const it of claimed) {
    const k = (it.added_dev || "") + "|" + low(it.added_by);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k)!.push(it);
  }
  const out: { sub: Sub; title: string; body: string; n: number }[] = [];
  for (const its of groups.values()) {
    const open = its.filter((i) => !i.checked);
    if (!open.length) continue;
    const dev = its[0].added_dev, by = low(its[0].added_by);
    const name = several ? family.find((f) => low(f.email) === by)?.name || null : null;
    for (const s of subs) {
      if (dev && s.dev === dev) continue;                         // ikke til den telefon, der tilføjede
      if (several && by && low(s.email) === by) continue;          // heller ikke til samme persons andre enheder
      const L = s.lang === "sq" ? TXT.sq : TXT.da;
      const names = open.map((i) => s.lang === "sq" ? (i.name_sq || i.name_da || i.text) : (i.name_da || i.text));
      const body = names.slice(0, MAX_NAMES).join(", ") + (names.length > MAX_NAMES ? " " + L.more(names.length - MAX_NAMES) : "");
      out.push({ sub: s, title: name ? L.who(name, open.length) : L.anon(open.length), body, n: open.length });
    }
  }
  return out;
}

/** Selve kørslen (testes lokalt med en falsk database og falsk afsendelse) */
// deno-lint-ignore no-explicit-any
export async function handle(req: Request, sb: any, deliver: (sub: Sub, payload: unknown) => Promise<unknown>) {
  // kun databasens egne planlagte kørsler må starte afsendelse (se cron_secret.sql)
  const { data: cs } = await sb.from("cron_secret").select("secret").eq("id", 1).maybeSingle();
  if (!cs?.secret || req.headers.get("x-cron-secret") !== cs.secret) return Response.json({ error: "ikke tilladt" }, { status: 401 });
  let alarm = false;
  try { alarm = !!(await req.json())?.alarm; } catch { /* tom krop: almindelig liste-besked */ }
  const isGone = (e: unknown) => [404, 410].includes((e as { statusCode?: number }).statusCode || 0);
  // 1) genforsøg, der er klar: kun til den telefon, der fejlede
  let retried = 0;
  const { data: due } = await sb.from("push_retry").select("id,endpoint,payload,tries").lte("next_at", new Date().toISOString()).limit(50);
  type Due = { id: number; endpoint: string; payload: unknown; tries: number };
  if (due?.length) {
    const { data: rs, error: rsErr } = await sb.from("push_subs").select("endpoint,p256dh,auth,dev,lang,email").in("endpoint", due.map((d: { endpoint: string }) => d.endpoint));
    // kunne abonnementerne ikke læses, venter genforsøgene til næste kørsel (intet slettes)
    for (const d of (rsErr || !rs ? [] : due) as Due[]) {
      const sub = ((rs || []) as Sub[]).find((x) => x.endpoint === d.endpoint);
      if (!sub) { await sb.from("push_retry").delete().eq("id", d.id); continue; }
      try { await deliver(sub, d.payload); await sb.from("push_retry").delete().eq("id", d.id); retried++; }
      catch (e) {
        if (isGone(e)) { await sb.from("push_subs").delete().eq("endpoint", sub.endpoint); }
        else if (d.tries < 5) { await sb.from("push_retry").update({ tries: d.tries + 1, next_at: new Date(Date.now() + 60000 * 2 ** d.tries).toISOString() }).eq("id", d.id); continue; }
        await sb.from("push_retry").delete().eq("id", d.id);
      }
    }
  }
  const { data: claimed, error } = alarm ? await sb.rpc("prisalarm_claim") : await sb.rpc("push_claim");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!claimed?.length) return Response.json({ claimed: 0, sent: 0, retried });
  const [{ data: subs }, { data: family }] = await Promise.all([
    sb.from("push_subs").select("endpoint,p256dh,auth,dev,lang,email"),
    sb.from("family").select("email,name"),
  ]);
  let sent = 0, gone = 0, failed = 0;
  const msgs = alarm ? planAlarms(claimed as Hit[], (subs || []) as Sub[]) : plan(claimed as Item[], (subs || []) as Sub[], family || []);
  for (const m of msgs) {
    const payload = { title: m.title, body: m.body, n: m.n };
    try { await deliver(m.sub, payload); sent++; }
    catch (e) {
      if (isGone(e)) { await sb.from("push_subs").delete().eq("endpoint", m.sub.endpoint); gone++; }
      else {   // midlertidig fejl: gem beskeden til netop denne telefon og prøv igen om lidt
        failed++; console.error("push fejlede", (e as { statusCode?: number }).statusCode, (e as { body?: string }).body);
        await sb.from("push_retry").insert({ endpoint: m.sub.endpoint, payload });
      }
    }
  }
  return Response.json({ claimed: claimed.length, sent, gone, failed, retried });
}

if (!Deno.env.get("PUSH_TEST")) {   // PUSH_TEST sættes kun i den lokale test
  const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, KEY || "x", { auth: { persistSession: false } });

  Deno.serve(async (req) => {
    if (!KEY) return Response.json({ error: "SUPABASE_SERVICE_ROLE_KEY mangler" }, { status: 500 });
    if (!Deno.env.get("VAPID_PRIVATE_KEY")) return Response.json({ error: "VAPID_PRIVATE_KEY mangler" }, { status: 500 });
    webpush.setVapidDetails(APP, VAPID_PUBLIC, Deno.env.get("VAPID_PRIVATE_KEY")!);
    return handle(req, sb, (sub, payload) => webpush.sendNotification(
      { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, JSON.stringify(payload), { TTL: 12 * 3600, urgency: "normal" }));
  });
}
