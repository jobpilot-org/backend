// Anschreiben: Schreibt mit dem KI-Key des Nutzers einen Entwurf (Betreff + fünf Abschnitte) oder
// einen einzelnen Abschnitt neu – aus dem Profil (ohne Kontaktdaten), der Stellenanzeige und den
// Vorgaben aus dem Assistenten. Gespeichert wird hier nichts; die App legt das Anschreiben am
// Stellenangebot bzw. an der Bewerbung ab.
//
// Token, KI-Key und Fehlercodes: siehe ../_shared/ai-request.ts.
//
// POST { mode: "draft", … }    →  200 { subject, sections, model }
// POST { mode: "section", … }  →  200 { text, model }

import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';

import { fail, json, serveAi } from '../_shared/ai-request.ts';
import {
  draftSchema,
  LETTER_SYSTEM_PROMPT,
  letterInputSchema,
  letterUserPrompt,
  sectionSchema,
} from './letter-schema.ts';

const MODEL = 'claude-opus-5-5';

function parseInput(body: unknown) {
  if (JSON.stringify(body ?? null).length > 300_000) return fail(413, 'too-large');
  const input = letterInputSchema.safeParse(body);
  if (!input.success) return fail(400, 'bad-request');
  if (input.data.mode === 'section' && !input.data.section) return fail(400, 'bad-request');
  return input.data;
}

serveAi('Anschreiben', parseInput, async (input, client) => {
  const draft = input.mode === 'draft';
  const stream = client.beta.messages.stream({
    model: MODEL,
    max_tokens: 8000,
    // Lehnt das Modell ab, springt serverseitig ein passendes Ersatzmodell ein
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    output_config: {
      effort: 'medium',
      format: draft ? betaZodOutputFormat(draftSchema) : betaZodOutputFormat(sectionSchema),
    },
    system: LETTER_SYSTEM_PROMPT,
    messages: [{ role: 'user', content: letterUserPrompt(input) }],
  });
  const message = await stream.finalMessage();

  if (message.stop_reason === 'refusal') return fail(422, 'refused');
  if (message.stop_reason === 'max_tokens' || !message.parsed_output) {
    return fail(502, 'incomplete');
  }
  return json(200, { ...(message.parsed_output as object), model: message.model });
});
