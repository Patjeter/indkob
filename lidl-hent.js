/* Indkøb · hent nye kvitteringer fra lidl.dk og send dem til appen.
   Køres (af den planlagte opgave) i en fane på https://www.lidl.dk/mre/purchase-history,
   mens man er logget ind på sin egen Lidl Plus-konto. Scriptet
   1) henter købsoversigten (10 køb pr. side) til og med `dage` dage tilbage,
   2) henter hver kvitterings trykte tekst (1,3 s pause, så Lidls server ikke belastes),
   3) åbner appen med kvitteringerne i adressens #-del (sendes aldrig til en server),
      hvor de vises og først gemmes, når man trykker "Gem".
   Intet login, ingen adgangskode og ingen nøgle er involveret: lidl.dk bruger den
   eksisterende indlogning i browseren, og appen gemmer med familiens egen indlogning.
   Brug: indsæt hele filen og kald  indkobHentLidl("besnik")  eller  indkobHentLidl("valentina"). */
async function indkobHentLidl(ejer, dage = 21, app = "https://patjeter.github.io/indkob/") {
  if (location.hostname !== "www.lidl.dk") throw new Error("Kør scriptet på www.lidl.dk");
  const since = Date.now() - dage * 864e5, tickets = [];
  const json = u => fetch(u, { credentials: "include" }).then(r => { if (!r.ok) throw new Error(`lidl.dk svarede ${r.status} – er du logget ind?`); return r.json() });
  const text = html => {
    // DOMParser giver et "dødt" dokument: ingen scripts køres og ingen billeder hentes
    const doc = new DOMParser().parseFromString(html || "", "text/html");
    doc.querySelectorAll("style,script").forEach(n => n.remove());
    return (doc.body ? doc.body.textContent : "").split("\n").map(s => s.replace(/\s+$/, "")).filter(s => s.trim()).join("\n");
  };
  for (let page = 1, done = false; page <= 6 && !done; page++) {
    const list = await json(`/mre/api/v1/tickets?country=DK&page=${page}`);
    const items = list.items || [];
    for (const it of items) {
      if (Date.parse(it.date) < since) { done = true; break }
      const t = (await json(`/mre/api/v1/tickets/${encodeURIComponent(it.id)}?country=DK&languageCode=da-DK`)).ticket || {};
      // oversigten har beløb og dato med tidszone; den enkelte kvittering har butik og tekst
      tickets.push({ id: String(it.id || t.id), date: it.date || t.date, store: (t.store && t.store.name) || null, total: it.totalAmount ?? null, text: text(t.htmlPrintedReceipt) });
      await new Promise(r => setTimeout(r, 1300));
    }
    if (items.length < 10) done = true;
  }
  const payload = encodeURIComponent(JSON.stringify({ ejer: ejer || null, tickets }));
  location.href = app + "#lidl=" + payload;
  return `${tickets.length} kvitteringer sendt til appen`;
}
