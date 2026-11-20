// Lebenslauf-Import: Nimmt ein PDF entgegen, schickt es mit dem KI-Key des angemeldeten Nutzers an
// Claude und gibt einen Profilentwurf zurück. Gespeichert wird hier nichts – die App zeigt den
// Entwurf zur Kontrolle und speichert ihn danach selbst über `replace_profile`.
//
// Ablauf wie in den API-Routen der mobile-app (src/server/ai-credentials.ts): Das Access-Token des
// Aufrufers wird bei Supabase geprüft, die RPC `get_ai_api_key()` liefert über `auth.uid()` genau
// dessen Key aus dem Vault. Der Key wird nie geloggt und nie zurückgegeben.
//
// POST { pdf: "<base64>" }  →  200 { profile } | 4xx/5xx { error: "<code>" }

import Anthropic from '@anthropic-ai/sdk';
import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';
import { createClient } from '@supabase/supabase-js';

import { CV_SYSTEM_PROMPT, CV_USER_PROMPT, cvSchema } from './cv-schema.ts';

const MODEL = 'claude-opus-5-5';
/** 10 MB PDF; Base64 ist ein Drittel größer */
const MAX_PDF_BYTES = 10 * 1024 * 1024;

// Die desktop-app lädt per file:// (Origin "null"), web-app und Dev-Server von localhost. Geprüft
// wird über das Bearer-Token, nicht über Cookies – deshalb ist ein offener Origin unbedenklich.
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

type ErrorCode =
  | 'unauthorized'
  | 'missing-key'
  | 'invalid-key'
  | 'bad-request'
  | 'too-large'
  | 'refused'
  | 'incomplete'
  | 'ai-unavailable'
  | 'unavailable';

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

const fail = (status: number, error: ErrorCode) => json(status, { error });

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

  let pdf: string;
  try {
    const body = (await request.json()) as { pdf?: unknown };
    if (typeof body.pdf !== 'string' || body.pdf === '') return fail(400, 'bad-request');
    pdf = body.pdf.replace(/\s/g, '');
  } catch {
    return fail(400, 'bad-request');
  }
  if ((pdf.length * 3) / 4 > MAX_PDF_BYTES) return fail(413, 'too-large');
  // Jedes PDF beginnt mit „%PDF-“, Base64 davon mit „JVBERi0“
  if (!pdf.startsWith('JVBERi0')) return fail(400, 'bad-request');

  const { data: apiKey, error: keyError } = await supabase.rpc('get_ai_api_key');
  if (keyError) {
    console.error('KI-Key aus dem Supabase Vault nicht lesbar:', keyError.message);
    return fail(503, 'unavailable');
  }
  if (typeof apiKey !== 'string' || apiKey.trim() === '') return fail(409, 'missing-key');

  const client = new Anthropic({ apiKey: apiKey.trim() });
  try {
    // Gestreamt, weil ein zweiseitiger Lebenslauf leicht eine Minute braucht
    const stream = client.beta.messages.stream({
      model: MODEL,
      max_tokens: 16000,
      // Lehnt das Modell ab, springt serverseitig ein passendes Ersatzmodell ein
      betas: ['server-side-fallback-2026-07-01'],
      fallbacks: 'default',
      output_config: { effort: 'medium', format: betaZodOutputFormat(cvSchema) },
      system: CV_SYSTEM_PROMPT,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: pdf } },
            { type: 'text', text: CV_USER_PROMPT },
          ],
        },
      ],
    });
    const message = await stream.finalMessage();

    if (message.stop_reason === 'refusal') return fail(422, 'refused');
    if (message.stop_reason === 'max_tokens' || !message.parsed_output) {
      return fail(502, 'incomplete');
    }
    return json(200, { profile: message.parsed_output });
  } catch (error) {
    if (error instanceof Anthropic.AuthenticationError || error instanceof Anthropic.PermissionDeniedError) {
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
    console.error('Lebenslauf-Import fehlgeschlagen:', error);
    return fail(502, 'ai-unavailable');
  }
});
