// Edge Function "lidl-priser": henter alle Lidl-varer fra Lidls kataloger (via Tjek-API'et) og gemmer
// standardpriser ("Fast lav pris"), førpriser og tilbudspriser i lidl_products / lidl_price_obs.
// Kaldes dagligt af pg_cron (se lidl_priser.sql). SUPABASE_URL og SUPABASE_SERVICE_ROLE_KEY sætter Supabase selv.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const DEALER = "71c90";                       // Lidl
const LAT = 55.6337, LNG = 12.6360, RADIUS = 10000;  // Kastrup
// Lidls egne mærker (Danmark) – bruges til at markere own_brand
const OWN = ["MILBONA", "ENGVANG", "MADVÆRKET", "BAKKEDAL", "LOVILIO", "DULANO", "CROWNFIELD", "BELLAROM", "SONDEY",
  "ALESTO", "VEMONDO", "CIEN", "DENTALUX", "W5", "FORMIL", "LUPILU", "COMBINO", "BARESA", "FIN CARRÉ", "SASKIA",
  "SOLEVITA", "KANIA", "SNACK DAY", "FAVORINA", "FREEWAY", "TASTINO", "PERLENBACHER", "DELUXE", "BELBAKE",
  "ITALIAMO", "GELATELLI", "CHEF SELECT", "VITA D'OR", "MCENNEDY", "EXQUISITA", "PILOS", "HAVBLÅ", "BUTCHER'S",
  "BUTCHER’S", "CHOCO NUSSA", "BIO ORGANIC", "MARIBEL", "NIXE", "SIEMPRE", "FLORALYS", "AROMATA", "LIBA",
  "GOLDEN SEAFOOD", "OCEAN SEA", "CRIVIT", "PARKSIDE", "SILVERCREST", "LIVARNO", "ESMARA", "LIVERGY", "PEPPERTS",
  "SUN SNACKS", "TRATTORIA ALFREDO", "CUISINE ROYAL", "GOURMET FINEST CUISINE", "LACTOFREE", "LACTO FREE",
  "BLUE WATER", "ECHT NORDISCH", "MARTAKA", "GOLDEN BRIDGE", "VITASIA", "SOL & MAR", "EL TEQUITO", "SNACK TIME",
  "HATHERWOOD", "J.D. GROSS", "MIREE", "RIVERCOTE", "MOMENTS", "ROMANI", "DEN GAMLE FABRIK"].map((s) => s.toUpperCase());

type Offer = {
  id: string; heading: string; description: string | null;
  pricing: { price: number | null; pre_price: number | null };
  quantity?: { unit?: { symbol?: string; si?: { symbol?: string; factor?: number } }; size?: { from?: number; to?: number } };
  run_from?: string; run_till?: string;
};

/** Mærke = ordene i starten skrevet med STORE bogstaver (fx "MADVÆRKET", "J.D. GROSS") */
export function brandOf(h: string): string {
  const out: string[] = [];
  for (const w of h.trim().split(/\s+/)) {
    if (/\p{Ll}/u.test(w) || !/\p{Lu}{2,}|\p{Lu}\.\p{Lu}|^\p{Lu}\d|^W5$/u.test(w)) break;
    out.push(w);
  }
  return out.join(" ");
}
const norm = (s: string) => s.toLowerCase().replace(/[’']/g, "'").replace(/[^\p{L}\p{N}'%]+/gu, " ").trim();

export function toRow(o: Offer) {
  const p = o.pricing || { price: null, pre_price: null };
  if (p.price == null || !o.heading) return null;
  const q = o.quantity || {}, u = q.unit || {}, si = u.si || {};
  const from = q.size?.from ?? null, to = q.size?.to ?? from;
  const sym = u.symbol || "";
  const siSym = si.symbol === "pcs" ? "stk" : (si.symbol || null);
  const qty = from != null && si.factor ? +(from * si.factor).toFixed(4) : null;
  const brand = brandOf(o.heading);
  const fast = /fast\s+lav\s+pris/i.test(o.description || "");
  const size = from == null ? "" : (to != null && to !== from ? `${from}-${to}` : `${from}`) + sym;
  return {
    id: o.id, pkey: `${norm(o.heading)}|${size}`, heading: o.heading.trim(), brand,
    own: brand !== "" && OWN.some((b) => brand.toUpperCase().startsWith(b)),
    size_from: from, size_to: to, unit: sym || null, qty_si: qty, si_unit: siSym,
    price: p.price, pre_price: p.pre_price, fast,
    valid_from: (o.run_from || "").slice(0, 10) || null, valid_to: (o.run_till || "").slice(0, 10) || null,
  };
}

export async function fetchAll(fetcher: typeof fetch = fetch): Promise<Offer[]> {
  const all: Offer[] = [];
  for (let off = 0; off < 3000; off += 100) {
    const url = `https://squid-api.tjek.com/v2/offers?dealer_ids=${DEALER}&r_lat=${LAT}&r_lng=${LNG}&r_radius=${RADIUS}&limit=100&offset=${off}`;
    const r = await fetcher(url, { headers: { "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36", accept: "*/*" } });
    if (!r.ok) throw new Error(`Tjek svarede ${r.status}`);
    const j = await r.json() as Offer[];
    all.push(...j);
    if (j.length < 100) break;
  }
  return all;
}

if (!Deno.env.get("PRICES_TEST")) {
  const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, KEY || "x", { auth: { persistSession: false } });
  Deno.serve(async () => {
    if (!KEY) return Response.json({ error: "SUPABASE_SERVICE_ROLE_KEY mangler" }, { status: 500 });
    try {
      const offers = await fetchAll();
      // samme vare kan stå flere gange (fx i to kataloger): behold alle – observationer har hver sit tilbuds-id
      const rows = offers.map(toRow).filter(Boolean);
      const { data, error } = await sb.rpc("lidl_ingest", { rows });
      if (error) return Response.json({ error: error.message }, { status: 500 });
      return Response.json({ hentet: offers.length, ...data });
    } catch (e) {
      return Response.json({ error: String(e) }, { status: 502 });
    }
  });
}
