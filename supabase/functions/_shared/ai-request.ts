// Gemeinsamer Rahmen der KI-Funktionen (cv-import, profile-review): CORS, JSON-Antworten mit
// Fehlercode, Prüfung des Access-Tokens und KI-Key des Aufrufers aus dem Vault.
//
// Ablauf wie in den API-Routen der mobile-app (src/server/ai-credentials.ts): Das Access-Token des
// Aufrufers wird bei Supabase geprüft, die RPC `get_ai_api_key()` liefert über `auth.uid()` genau
// dessen Key aus dem Vault. Der Key wird nie geloggt und nie zurückgegeben.

import Anthropic from '@anthropic-ai/sdk';
import { createClient } from '@supabase/supabase-js';

// Die desktop-app lädt per file:// (Origin "null"), web-app und Dev-Server von localhost. Geprüft
// wird über das Bearer-Token, nicht über Cookies – deshalb ist ein offener Origin unbedenklich.
export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

export type ErrorCode =
  | 'unauthorized'
  | 'missing-key'
  | 'invalid-key'
  | 'bad-request'
  | 'too-large'
  | 'refused'
  | 'incomplete'
  | 'ai-unavailable'
  | 'unavailable';

export function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

export const fail = (status: number, error: ErrorCode) => json(status, { error });

function publishableKey() {
  // Neuere CLI-Versionen setzen SUPABASE_PUBLISHABLE_KEYS (JSON), ältere nur SUPABASE_ANON_KEY
  const keys = Deno.env.get('SUPABASE_PUBLISHABLE_KEYS');
  if (keys) {
    try {
      const parsed = JSON.parse(keys) as Record<string, string>;
      const first = parsed.default ?? Object.values(parsed)[0];
      if (first) return first;
    } catch {
      // weiter mit dem Anon-Key
    }
  }
  return Deno.env.get('SUPABASE_ANON_KEY') ?? '';
}

/**
 * Bedient OPTIONS, prüft Methode und Token, dann mit `parse` den Body (Response = Fehler) und ruft
 * `handle` mit dem Ergebnis und einem Anthropic-Client mit dem Key des Aufrufers auf. Der Key wird
 * erst nach gültigem Body gelesen. Fehler des KI-Dienstes werden einheitlich auf Fehlercodes
 * abgebildet; `label` steht nur in den Logs.
 */
export function serveAi<T>(
  label: string,
  parse: (body: unknown) => T | Response,
  handle: (input: T, client: Anthropic) => Promise<Response>,
) {
  Deno.serve(async (request) => {
    if (request.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
    if (request.method !== 'POST') return fail(405, 'bad-request');

    const token = request.headers.get('authorization')?.match(/^Bearer\s+(\S+)$/i)?.[1];
    if (!token) return fail(401, 'unauthorized');

    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', publishableKey(), {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });

    // Die Identität stammt nur aus dem geprüften Token, nie aus dem Body
    try {
      const { data, error } = await supabase.auth.getUser(token);
      if (error) {
        const rejected = error.status !== undefined && error.status >= 400 && error.status < 500;
        return fail(rejected ? 401 : 503, rejected ? 'unauthorized' : 'unavailable');
      }
      if (!data.user) return fail(401, 'unauthorized');
    } catch {
      return fail(503, 'unavailable');
    }

    let input: T | Response;
    try {
      input = parse(await request.json());
    } catch {
      return fail(400, 'bad-request');
    }
    if (input instanceof Response) return input;

    const { data: apiKey, error: keyError } = await supabase.rpc('get_ai_api_key');
    if (keyError) {
      console.error('KI-Key aus dem Supabase Vault nicht lesbar:', keyError.message);
      return fail(503, 'unavailable');
    }
    if (typeof apiKey !== 'string' || apiKey.trim() === '') return fail(409, 'missing-key');

    try {
      return await handle(input, new Anthropic({ apiKey: apiKey.trim() }));
    } catch (error) {
      if (
        error instanceof Anthropic.AuthenticationError ||
        error instanceof Anthropic.PermissionDeniedError
      ) {
        return fail(409, 'invalid-key');
      }
      if (error instanceof Anthropic.BadRequestError) {
        // z. B. beschädigtes oder passwortgeschütztes PDF
        console.error('KI-Dienst lehnt die Anfrage ab:', error.message);
        return fail(400, 'bad-request');
      }
      if (error instanceof Anthropic.APIError) {
        console.error('KI-Dienst antwortet mit Status', error.status);
        return fail(502, 'ai-unavailable');
      }
      console.error(`${label} fehlgeschlagen:`, error);
      return fail(502, 'ai-unavailable');
    }
  });
}
