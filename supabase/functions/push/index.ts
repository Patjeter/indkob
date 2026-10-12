// Edge Function "push": sender én samlet notifikation, når nogen har tilføjet varer til indkøbslisten.
// Kaldes hvert minut af pg_cron (se push.sql), men kun når der er varer, der venter.
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

if (!Deno.env.get("PUSH_TEST")) {   // PUSH_TEST sættes kun i den lokale test
  webpush.setVapidDetails(APP, VAPID_PUBLIC, Deno.env.get("VAPID_PRIVATE_KEY") || "");
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  Deno.serve(async () => {
    if (!Deno.env.get("VAPID_PRIVATE_KEY")) return Response.json({ error: "VAPID_PRIVATE_KEY mangler" }, { status: 500 });
    const { data: claimed, error } = await sb.rpc("push_claim");
    if (error) return Response.json({ error: error.message }, { status: 500 });
    if (!claimed?.length) return Response.json({ claimed: 0, sent: 0 });
    const [{ data: subs }, { data: family }] = await Promise.all([
      sb.from("push_subs").select("endpoint,p256dh,auth,dev,lang,email"),
      sb.from("family").select("email,name"),
    ]);
    let sent = 0, gone = 0;
    for (const m of plan(claimed as Item[], (subs || []) as Sub[], family || [])) {
      try {
        await webpush.sendNotification(
          { endpoint: m.sub.endpoint, keys: { p256dh: m.sub.p256dh, auth: m.sub.auth } },
          JSON.stringify({ title: m.title, body: m.body, n: m.n }),
          { TTL: 12 * 3600, urgency: "normal" },
        );
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) { await sb.from("push_subs").delete().eq("endpoint", m.sub.endpoint); gone++; }
        else console.error("push fejlede", code, (e as { body?: string }).body);
      }
    }
    return Response.json({ claimed: claimed.length, sent, gone });
  });
}
