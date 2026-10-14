# Audit-pakke for Indkøb

Alt, en uafhængig gennemgang skal bruge for at vurdere familiens indkøbsapp uden adgang til de rigtige data. Pakken indeholder ingen navne, e-mails, kvitteringer eller priser fra familien.

## Hvad appen er

En web-app (PWA) for en familie på fire i Kastrup: to voksne og to børn på 11 og 6 år. Den har en fælles indkøbsliste på dansk og albansk. Hver morgen henter den tilbud fra 7 kæder og Lidls faste priser, og den lærer familiens købsrytme fra Lidl Plus-kvitteringer.

- App: `index.html` (én fil), `sw.js`, `manifest.webmanifest`. Hostes på GitHub Pages.
- Database: Supabase (Postgres med række-sikkerhed, login, pg_cron, Edge Function `push`).
- SQL: `schema.sql`, `push.sql`, `tilbud_auto.sql`, `lidl_priser.sql`, `lidl_soeg.sql`, `kvit.sql`, `dishes_v2.sql`, `butik_orden.sql`, `prisalarm.sql`, `tilbud_for.sql`, `ugeanalyse.sql`, `familie_regler.sql` (én fælles kontrol af familiens regler), `drift.sql` (status for automatikken; samles i e-mail søndag aften), `handle.sql` ("Kan du handle nu?" med svar).
- Edge Function: `supabase/functions/push/index.ts` (web push).
- Kvitteringer: `lidl-hent.js` (køres i brugerens egen Chrome på lidl.dk) og `kvit-parse.js`.

## Mål og faste regler

Målene, i prioriteret rækkefølge:
1. **Mindre arbejde.** Ingen skal selv bladre i 7 tilbudsaviser.
2. **Bedre kvalitet.** Økologisk eller bedre varer, når de koster det samme.
3. **Besparelse** er en sidegevinst, ikke hovedformålet.

Designprincipper:
- Det skal være lige så enkelt som at skrive på en indkøbsliste.
- Varerne står i butikkens rækkefølge.
- Lidl er standard. En anden butik kommer kun med, når familien samlet sparer mindst 50 kr. dér.

Faste regler, som al matchning skal overholde:
- Intet svinekød. Pålæg og pølser kun af kylling, kalkun eller fisk. Slik kun uden svinegelatine.
- Oksekød købes kun hos Al-Rafiden Slagteri, så det må aldrig foreslås fra andre kæder.
- Kaffe er kun Merrild Rød.
- Laktosefri og økologiske valg bevares.

## Det, der skal vurderes

Giv for hvert punkt en vurdering (god / acceptabel / svag), de vigtigste fund med fil og linje, og en konkret anbefaling.

1. **Sikkerhed.** Række-sikkerhed, rettigheder, funktioner med `security definer`, hemmeligheder, XSS og CSP, Edge Function, planlagte opgaver der læser tekst fra internettet (prompt injection), og børns adgang.
2. **Design.** Læsbarhed på iPhone (402 × 874), konsistens, tomme tilstande og fejltekster, tilgængelighed (kontrast, fokus, aria) og desktop.
3. **Funktionalitet.** Logikken i tilbud, totaler, butiksvalg, prisalarm, butikkens rækkefølge, kvitteringsimport og arbejde uden net. Find fejl og kanttilfælde.
4. **Helhed.** Hænger appen sammen, eller er den ved at blive for stor i forhold til princippet om enkelhed?
5. **Hverdagsbrug.** Hvor mange tryk tager de almindelige opgaver? Hvad sker der i butikken med dårligt net og én hånd fri?
6. **Lever vi op til målene?** Brug `db_opsaetning.json` → `brug_pr_uge` til at vurdere, om appen faktisk bruges.

## Sådan kører du appen uden adgang

```
python3 -m http.server 8766        # fra repoets rod
# åbn http://localhost:8766/?demo           (opfundne data, ingen database)
# åbn http://localhost:8766/?demo&reset     (start forfra med demodata)
```

`?demo` bruger `audit/demo.json` og gemmer alt under egne nøgler i browseren. Der sendes intet til databasen; `tests/demo.test.js` tjekker det.

```
npm i playwright && npx playwright install chromium
node audit/tests/demo.test.js
```

## Filer i pakken

| Fil | Indhold |
| --- | --- |
| `db_opsaetning.json` | Udtræk fra den rigtige database den 13. okt. 2026: tabeller og række-sikkerhed, politikker, rettigheder for `anon` og `authenticated`, funktioner (definer, search_path, hvem må kalde), planlagte kørsler (nøgler skjult), antal brugere, omfang og brug pr. uge. Ingen data. Mellemrum i cron-kommandoerne er komprimeret. |
| `demo.json` | Opfundne varer, tilbud, retter og Lidl-alternativer til demo-tilstand. |
| `tests/demo.test.js` | Røgtest af demo-tilstand. |
| `tests/koe-og-tilbud.test.js` | Køen (rækkefølge, afviste ændringer, genforsøg ved netfejl), maks og valgte tilbud. Bruger `tests/mock-supabase.js`. |
| `tests/afhaengige-aendringer.test.js` | En afvist oprettelse stopper afkrydsning af samme vare; et valgt tilbud vinder over et eksisterende i samme butik. |
| `tests/push-retry.test.ts` | Push: hemmelighed, genforsøg pr. telefon, at en læsefejl ikke sletter genforsøg, og "Kan du handle nu?" (Deno). |
| `CODEX_PROMPT.md` | Færdig opgavetekst til en gennemgang. |

## Kendte forhold (så de ikke skal genfindes)

- Den offentlige `anonKey` står i `config.js` og `push.sql`. Det er meningen; adgang styres af række-sikkerhed og familielisten.
- Familien har valgt, at børn har samme adgang som de voksne.
- Planlagte opgaver kører på familiens Mac via Claude in Chrome: tilbud og kvitteringer søndag og torsdag aften, ugens analyse søndag aften.
- Prisalarm, butikkens rækkefølge, kvitteringsimport og ugens analyse er bygget, men endnu ikke kørt i virkeligheden.
