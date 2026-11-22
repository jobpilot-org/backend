# backend

Supabase-Projekt von jobpilot: Datenbankschema, Migrationen und Datenbanktests.

Die App speichert ihre Bewerbungen lokal in SQLite. Hier liegt nur, was zentral sein muss: die
Anmeldung (`auth.users`) und – seit dem Wechsel auf eigene Anthropic-Keys – der verschlüsselte
API-Key je Nutzer.

## Inhalt

```
supabase/
  config.toml                    Einstellungen der lokalen Instanz (Ports, Auth, Seeds)
  migrations/                    versioniertes Schema, wird der Reihe nach angewendet
  tests/                         pgTAP-Tests für Schema, Rechte und Lebenszyklus
```

`supabase/migrations/20261116074647_ai_api_key.sql` legt an:

- `public.ai_api_keys` – eine Zeile je Nutzer mit der ID des Vault-Secrets und Zeitstempeln,
  aber ohne Key-Material,
- RLS und explizite Grants: `authenticated` liest nur die eigene Zeile und schreibt nie direkt,
- die RPCs `save_ai_api_key(text)`, `delete_ai_api_key()` (beide leiten die
  Eigentümerschaft aus `auth.uid()` ab) und `get_ai_api_key()` (liest allein über `auth.uid()`,
  ausführbar nur für `authenticated`),
- einen Trigger, der das Vault-Secret zusammen mit der Metadatenzeile entfernt.

Die Entschlüsselung braucht damit keinen Service-Rollen-Schlüssel: Der API-Server schickt das
Bearer-Token des Aufrufers, und `get_ai_api_key()` liest allein über `auth.uid()` dessen Key.

`supabase/migrations/20261119180000_app_data.sql` legt die Anwendungsdaten an, auf die alle Apps
zugreifen: `applications`, `status_events`, `contacts`, `notes`, `appointments`, `reminders` und
`settings` – gespiegelt aus dem Drizzle-Schema der mobile-app, ergänzt um `user_id` (Standard
`auth.uid()`). RLS beschränkt jeden Nutzer auf die eigenen Zeilen; Kindtabellen verweisen über
`(user_id, application_id)` auf ihre Bewerbung und können so nie an eine fremde hängen. Zeitpunkte
sind `timestamptz`, `applied_at` ist `date`; IDs bleiben `text`, damit die von den Apps erzeugten IDs
übernommen werden können.

`supabase/migrations/20261119180100_status_event_trigger.sql` überlässt den Statusverlauf der
Datenbank: Ein Trigger auf `applications` schreibt beim Anlegen `null → status` (zum `created_at`)
und bei jedem Statuswechsel `alt → neu` (zu `now()`) nach `status_events` – in derselben Anweisung
wie die Änderung. Die Apps lesen den Verlauf nur noch; schreiben, ändern oder löschen können sie ihn
nicht.

`supabase/migrations/20261120073146_profile.sql` legt das Profil (Lebenslauf) an: `profiles` (eine
Zeile je Nutzer mit Kopfdaten, Kurzprofil und `onboarded_at` für die Willkommensseite),
`profile_entries` (Berufserfahrung und Ausbildung, unterschieden über `kind`; Zeiträume als `YYYY`
oder `YYYY-MM`), `profile_skills` und `profile_languages`, alle mit RLS auf die eigenen Zeilen. Die
RPC `replace_profile(jsonb)` ersetzt das ganze Profil in einer Transaktion (PDF-Import, Assistent).

`supabase/migrations/20261122070714_job_postings.sql` legt `job_postings` an: gemerkte
Stellenangebote (z. B. aus der Browser-Extension), getrennt von Bewerbungen. Wird aus einem
Stellenangebot eine Bewerbung, zeigt `application_id` darauf (je Bewerbung höchstens ein
Stellenangebot; Löschen der Bewerbung hebt nur die Verknüpfung auf); `dismissed_at` markiert
„nicht interessant“.

`supabase/functions/cv-import` ist eine Edge Function für den Lebenslauf-Import: Sie nimmt ein PDF
(Base64) entgegen, prüft das Bearer-Token bei Supabase, holt über `get_ai_api_key()` den KI-Key des
Aufrufers und lässt Claude daraus einen Profilentwurf lesen. Gespeichert wird nichts; die App zeigt
den Entwurf zur Kontrolle und ruft danach `replace_profile` auf.

`supabase/functions/profile-review` ist der KI-Check des Profils auf grobe inhaltliche Fehler
(Widersprüche, Zeiträume, Lücken, fehlende Pflichtangaben, Doppelungen, Tippfehler) – ohne Bezug
auf eine Stelle. Sie nimmt das Profil ohne Name und Kontaktdaten (nur, ob sie vorhanden sind)
entgegen und liefert Punktzahl (0–100), Gesamteinschätzung, Stärken und Korrekturvorschläge, teils
mit fertigem Ersatztext für Berufsbezeichnung, Kurzprofil, Stichpunkte einer Station oder eine
Kenntnisgruppe.
Gespeichert wird nichts; übernommene Vorschläge schreibt die App selbst.

`supabase/functions/job-import` liest aus dem Text einer Stellenanzeige (z. B. dem sichtbaren
Seitentext, den die Browser-Extension schickt) die Eckdaten für eine Bewerbung: Firma, Rolle, Ort,
Arbeitsmodell, Gehalt, geforderte Fähigkeiten, Ansprechpartner und eine Kurzbeschreibung – im
selben Format wie „Bewerbung aus Stellenanzeige“ der mobile-app. Gespeichert wird nichts; die
Extension legt danach selbst eine Bewerbung mit Status `saved` („Gemerkt“) an.

Token-Prüfung, KI-Key aus dem Vault und Fehlercodes teilen sich alle Funktionen in
`supabase/functions/_shared/ai-request.ts`. Lokal laufen sie mit `supabase start`; ins gehostete
Projekt mit `supabase functions deploy cv-import profile-review job-import`.

## Lokal starten

Voraussetzung: [Supabase CLI](https://supabase.com/docs/guides/cli) und Docker.

```bash
supabase start        # startet Postgres, Auth, API und Studio, wendet alle Migrationen an
supabase status       # URLs und Keys, auch später jederzeit abrufbar
```

- API: `http://localhost:54321`, Studio: `http://localhost:54323`, Datenbank: Port `54322`
- Die Werte für die App stehen in `../mobile/.env.local` (siehe `../mobile/README.md`).
- Sign-ups sind freigeschaltet (`enable_signup = true`, Passwort mind. 8 Zeichen mit Buchstaben und Ziffern; Großbuchstabe und Sonderzeichen verlangen die Apps); Vor- und Nachname speichern die Apps in `user_metadata`. Im gehosteten Projekt muss „Allow new users to sign up“ im Dashboard ebenfalls an sein. Außerdem ist dort unter *Authentication → Sign In / Providers → Email* „Confirm email“ ausgeschaltet (wie lokal `enable_confirmations = false`): Der eingebaute Mailversand stellt nur an Team-Adressen zu, und der Bestätigungslink führt auf die Site URL, die keine der Apps bedient. Mit Bestätigung bliebe die Registrierung bei „E-Mail bestätigen“ hängen.

## Migrationen

```bash
supabase migration new kurze_beschreibung   # leere Migration anlegen
supabase db reset                           # lokale Datenbank neu aufbauen: alle Migrationen
supabase db push                            # Migrationen auf das verknüpfte Cloud-Projekt anwenden
supabase migration list                     # lokal und remote vergleichen
```

Eine Änderung an einer bereits angewendeten Migration wird nicht nachgezogen – für jede Änderung
kommt eine neue Datei dazu. `supabase db reset` löscht die lokalen Daten, ist also der saubere Weg,
um den kompletten Migrationspfad zu prüfen.

## Datenbanktests

```bash
supabase test db
```

Die pgTAP-Tests in `supabase/tests/` laufen gegen die lokale Datenbank. Sie prüfen unter anderem:

- Spalten und Primärschlüssel der Tabelle, keine Key-Spalte,
- RLS und Tabellenrechte für `anon` und `authenticated`,
- dass nur `authenticated` den eigenen Key entschlüsseln darf und `anon` wie `service_role` nicht,
- dass die Entschlüsselungs-RPC keinen Nutzer-Parameter hat und deshalb keinen fremden Key liefern
  kann,
- dass Speichern, Ersetzen und Löschen die Eigentümerschaft aus der Session ziehen,
- dass weder Ersetzen noch Löschen noch das Entfernen des Auth-Nutzers Vault-Secrets zurücklassen.

Die Tests laufen in einer Transaktion und räumen ihre Testnutzer wieder auf; `supabase test db`
setzt voraus, dass die lokale Instanz läuft (`supabase start`).
