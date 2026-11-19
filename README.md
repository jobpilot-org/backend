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

## Lokal starten

Voraussetzung: [Supabase CLI](https://supabase.com/docs/guides/cli) und Docker.

```bash
supabase start        # startet Postgres, Auth, API und Studio, wendet alle Migrationen an
supabase status       # URLs und Keys, auch später jederzeit abrufbar
```

- API: `http://localhost:54321`, Studio: `http://localhost:54323`, Datenbank: Port `54322`
- Die Werte für die App stehen in `../mobile/.env.local` (siehe `../mobile/README.md`).
- Konten werden im Studio angelegt oder per Seed-SQL; Sign-ups sind abgeschaltet.

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
