# Hvad appen er til, og hvad hver funktion skal kunne

Skrevet til en uafhængig bedømmelse. Bedøm hver funktion på en skala fra 1 til 10 ud fra, hvor godt den **i dag** lever op til sit formål. Begrund kort, og skeln mellem det, du har set i koden eller demoen, og det, der kun kan vurderes ved rigtig brug.

## Formålet

Familien (to voksne og to børn på 11 og 6 år i Kastrup) handler stort én gang om ugen, næsten kun i Lidl. Ingen har overskud til at gennemgå 7 tilbudsaviser. Appen skal derfor:

1. **Spare arbejde:** være lige så enkel som at skrive på en delt indkøbsliste, mens alt det tunge sker af sig selv.
2. **Give bedre kvalitet:** økologisk eller laktosefrit og de rigtige mærker, når det ikke koster mere.
3. **Spare penge som en sidegevinst:** kun nævne en anden butik, når det er besværet værd (50 kr.-reglen).

Faste regler: intet svinekød (heller ikke gelatine i slik), oksekød kun fra Al-Rafiden Slagteri, kaffe kun Merrild Rød, og laktosefri og økologiske valg bevares. Appen er tosproget (dansk/albansk).

## Funktionerne og deres formål

| # | Funktion | Formål – hvad den skal gøre for familien |
| --- | --- | --- |
| 1 | Fælles indkøbsliste | Begge (alle fire) skriver på samme liste, der opdateres live, virker uden net og er sorteret efter butik og kategori. |
| 2 | Søgning og tilføjelse | Finde varen hurtigt fra få bogstaver, også på albansk, med flere ord og "uden laktose", og med det, familien plejer at købe, først. |
| 3 | Priser og total | Vise, hvad listen koster, pris pr. stk. og i alt pr. vare, subtotal pr. kategori og hvad familien sparer. |
| 4 | Tilbud fra 7 kæder | Hente aviserne hver morgen og kun vise tilbud, der passer til familiens egne varer og regler. |
| 5 | Butiksvalg og 50 kr.-reglen | Lade Lidl være standard, foreslå en anden butik kun når det samlet sparer mindst 50 kr., men altid lade familien selv vælge et tilbud. |
| 6 | Sammenlign | Vise alle aktuelle og kommende tilbud på én vare på tværs af kæder, med pris pr. kg/stk. og maks antal, og lade familien vælge. |
| 7 | Forslag ud fra købsrytme | Minde om varer, der er ved at slippe op (14 dage, 30 dage), ud fra familiens egne kvitteringer. |
| 8 | Lidls sortiment og mærkeskift | Kunne finde alle Lidls varer og foreslå Lidls egne mærker, når de er billigere, uden at bryde reglerne. |
| 9 | Retter og madpakker | Lægge ingredienserne til familiens retter (også kosovo-albanske) og børnenes madpakker på listen med ét tryk, med links til opskrifter. |
| 10 | Butikkens rækkefølge | Sortere listen efter vejen gennem butikken, lært af afkrydsninger eller sat manuelt. |
| 11 | Kvitteringer fra Lidl Plus | Hente kvitteringerne automatisk, holde købsrytme og priser opdateret og krydse købte varer af. |
| 12 | Notifikationer | Give den anden besked, når der kommer nye varer på listen, på dansk eller albansk. |
| 13 | Prisalarm | Give besked, når en vare kommer på tilbud under familiens egen grænse. |
| 14 | Ugens analyse | Hver søndag skrive få konkrete forslag til handlen og appen i familiens dokument. |
| 15 | Sikkerhed og privatliv | Kun familien kan se data, intet privat i det offentlige repo, og automatikken kan ikke misbruges udefra. |
| 16 | Drift | Køre gratis og uden vedligehold; fejl i kilderne skal opdages. |

## Det, der skal leveres

Tilføj et afsnit til `audit/rapport-2026-10-13.md` med:

- en tabel med funktion, karakter (1–10) og én linjes begrundelse
- en samlet karakter for, hvor godt appen i dag lever op til formålet
- de tre ændringer, der vil løfte karaktererne mest

Kald ikke den rigtige database, og ændr ikke koden.
