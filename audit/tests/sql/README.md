# SQL-tests (PGlite – Postgres i Node, ingen rigtig database)

Hver fil indlæser én eller flere SQL-filer fra repoets rod i en tom PGlite-database med falske
`auth`, `net`, `cron` og `is_family()`, og tjekker funktionerne med opfundne data.

```
cd audit/tests/sql && npm i @electric-sql/pglite
node regeltest.mjs     # familie_regel(): svinekød, oksekød, gelatine, kaffe
node sqltest6.mjs      # Lidl-søgning og øko-alternativ med familiens regler
node alarmtest.mjs     # prisalarm: fund, claim, ingen dobbeltbesked
node drifttest.mjs     # status_automatik, drift_tjek, drift_uge
node handletest.mjs    # "Kan du handle nu?": spørg, nej, ja, for sent, fremmede afvises
node turtest.mjs       # turforslag i jeres butikker, besked højst én gang om dagen, seneste pris pr. pakning
node nodlagertest.mjs   # nødlager: kun familien, hvem ændrede, højst 2 uger, realtime, besked før holdbarhed udløber (én gang pr. dato)
```

Push-funktionen testes med Deno: `PUSH_TEST=1 deno run -A ../push-retry.test.ts`.
