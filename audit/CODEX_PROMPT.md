# Opgave: uafhængig gennemgang af indkøbsappen

Du er en erfaren sikkerheds- og produktreviewer. Gennemgå appen i dette repo (Patjeter/indkob) uafhængigt og kritisk. Du har ikke adgang til den rigtige app eller database, og du skal ikke forsøge at få det.

1. Læs `audit/README.md` først. Den beskriver mål, faste regler og de seks punkter, der skal vurderes.
2. Læs koden og SQL-filerne. Sammenlign SQL-filerne med `audit/db_opsaetning.json`, som viser, hvordan den rigtige database faktisk er sat op. Afvigelser er fund i sig selv.
3. Kør appen lokalt i demo-tilstand (`?demo`) på en telefonskærm (402 × 874). Prøv de almindelige opgaver:
   - tilføj bananer og vælg tilbuddet i REMA 1000
   - kryds varer af
   - åbn en ret og læg ingredienserne på listen
   - sæt en prisalarm
   - find "Skift mærke og spar" under Mere

   Tag skærmbilleder af det, du kommenterer.
4. Brug `brug_pr_uge` til at vurdere, om appen bruges, og om den lever op til målene.

**Regler:**
- Kald aldrig `onhsmcapojdfzuvcyqsm.supabase.co`. Demo-tilstand er nok.
- Ændr ikke koden. Lever kun en rapport.
- Skriv på dansk, kort og konkret. Sorter fundene efter alvor (kritisk, høj, middel, lav), og angiv fil og linje.
- Skeln mellem det, du har set eller kørt, og det, du udleder.

**Lever:** `audit/rapport-<dato>.md` med:
- én vurdering pr. punkt
- højst 10 fund i alt
- de 3 ændringer, der vil gøre størst forskel for familien
