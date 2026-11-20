// Profil-Check: Nimmt das Profil des angemeldeten Nutzers (ohne Kontaktdaten) und optional eine
// Zielposition entgegen, lässt es mit dem KI-Key des Nutzers von Claude bewerten und gibt
// Bewertung, Stärken und Verbesserungsvorschläge zurück. Gespeichert wird hier nichts – Vorschläge
// übernimmt die App einzeln über die normalen Profil-Repositories.
//
// Token, KI-Key und Fehlercodes: siehe ../_shared/ai-request.ts.
//
// POST { profile, targetRole? }  →  200 { review } | 4xx/5xx { error: "<code>" }

import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';

import { fail, json, serveAi } from '../_shared/ai-request.ts';
import { REVIEW_SYSTEM_PROMPT, reviewInputSchema, reviewSchema, reviewUserPrompt } from './review-schema.ts';

const MODEL = 'claude-opus-5-5';

function parseInput(body: unknown) {
  if (JSON.stringify(body ?? null).length > 200_000) return fail(413, 'too-large');
  const input = reviewInputSchema.safeParse(body);
  return input.success ? input.data : fail(400, 'bad-request');
}

serveAi('Profil-Check', parseInput, async (input, client) => {
  // Gestreamt, weil eine gründliche Bewertung eine Weile braucht
  const stream = client.beta.messages.stream({
    model: MODEL,
    max_tokens: 16000,
    // Lehnt das Modell ab, springt serverseitig ein passendes Ersatzmodell ein
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    output_config: { effort: 'medium', format: betaZodOutputFormat(reviewSchema) },
    system: REVIEW_SYSTEM_PROMPT,
    messages: [{ role: 'user', content: reviewUserPrompt(input) }],
  });
  const message = await stream.finalMessage();

  if (message.stop_reason === 'refusal') return fail(422, 'refused');
  if (message.stop_reason === 'max_tokens' || !message.parsed_output) {
    return fail(502, 'incomplete');
  }
  return json(200, { review: message.parsed_output });
});
