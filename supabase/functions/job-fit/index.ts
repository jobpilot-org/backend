// Passung: Bewertet mit dem KI-Key des Nutzers, wie gut sein Profil (ohne Kontaktdaten) zu einem
// Stellenangebot passt – Score, Pros, Contras, Prognose. Gespeichert wird hier nichts; die App legt
// das Ergebnis mit Hashes von Profil und Anzeigentext am Stellenangebot ab.
//
// Token, KI-Key und Fehlercodes: siehe ../_shared/ai-request.ts.
//
// POST { profile, posting }  →  200 { fit, model } | 4xx/5xx { error: "<code>" }

import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';

import { fail, json, serveAi } from '../_shared/ai-request.ts';
import { FIT_SYSTEM_PROMPT, fitInputSchema, fitSchema, fitUserPrompt } from './fit-schema.ts';

const MODEL = 'claude-opus-5-5';

function parseInput(body: unknown) {
  if (JSON.stringify(body ?? null).length > 250_000) return fail(413, 'too-large');
  const input = fitInputSchema.safeParse(body);
  return input.success ? input.data : fail(400, 'bad-request');
}

serveAi('Passung', parseInput, async (input, client) => {
  const stream = client.beta.messages.stream({
    model: MODEL,
    max_tokens: 8000,
    // Lehnt das Modell ab, springt serverseitig ein passendes Ersatzmodell ein
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    output_config: { effort: 'medium', format: betaZodOutputFormat(fitSchema) },
    system: FIT_SYSTEM_PROMPT,
    messages: [{ role: 'user', content: fitUserPrompt(input) }],
  });
  const message = await stream.finalMessage();

  if (message.stop_reason === 'refusal') return fail(422, 'refused');
  if (message.stop_reason === 'max_tokens' || !message.parsed_output) {
    return fail(502, 'incomplete');
  }
  return json(200, { fit: message.parsed_output, model: message.model });
});
