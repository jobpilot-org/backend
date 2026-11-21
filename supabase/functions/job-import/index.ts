// Stellenanzeigen-Import: Nimmt den Text einer Stellenanzeige (z. B. von der Browser-Extension, die
// den sichtbaren Seitentext schickt) entgegen und lässt Claude mit dem KI-Key des Nutzers die
// Eckdaten herauslesen. Gespeichert wird hier nichts – die App bzw. Extension zeigt die Daten zur
// Kontrolle und legt danach selbst die Bewerbung (Status „Gemerkt“) an.
//
// Token, KI-Key und Fehlercodes: siehe ../_shared/ai-request.ts.
//
// POST { posting, url? }  →  200 { job } | 4xx/5xx { error: "<code>" }

import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';

import { fail, json, serveAi } from '../_shared/ai-request.ts';
import { JOB_SYSTEM_PROMPT, jobInputSchema, jobSchema, jobUserPrompt, MAX_POSTING_CHARS } from './job-schema.ts';

const MODEL = 'claude-opus-5-5';

function parseInput(body: unknown) {
  const posting = (body as { posting?: unknown } | null)?.posting;
  if (typeof posting === 'string' && posting.trim().length > MAX_POSTING_CHARS) {
    return fail(413, 'too-large');
  }
  const input = jobInputSchema.safeParse(body);
  return input.success ? input.data : fail(400, 'bad-request');
}

serveAi('Stellenanzeigen-Import', parseInput, async (input, client) => {
  const stream = client.beta.messages.stream({
    model: MODEL,
    max_tokens: 4000,
    // Lehnt das Modell ab, springt serverseitig ein passendes Ersatzmodell ein
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    // Reines Herauslesen von Eckdaten – wenig Nachdenken nötig, dafür schnell
    output_config: { effort: 'low', format: betaZodOutputFormat(jobSchema) },
    system: JOB_SYSTEM_PROMPT,
    messages: [{ role: 'user', content: jobUserPrompt(input) }],
  });
  const message = await stream.finalMessage();

  if (message.stop_reason === 'refusal') return fail(422, 'refused');
  if (message.stop_reason === 'max_tokens' || !message.parsed_output) {
    return fail(502, 'incomplete');
  }
  return json(200, { job: message.parsed_output });
});
