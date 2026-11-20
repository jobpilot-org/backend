// Lebenslauf-Import: Nimmt ein PDF entgegen, schickt es mit dem KI-Key des angemeldeten Nutzers an
// Claude und gibt einen Profilentwurf zurück. Gespeichert wird hier nichts – die App zeigt den
// Entwurf zur Kontrolle und speichert ihn danach selbst über `replace_profile`.
//
// Token, KI-Key und Fehlercodes: siehe ../_shared/ai-request.ts.
//
// POST { pdf: "<base64>" }  →  200 { profile } | 4xx/5xx { error: "<code>" }

import { betaZodOutputFormat } from '@anthropic-ai/sdk/helpers/beta/zod';

import { fail, json, serveAi } from '../_shared/ai-request.ts';
import { CV_SYSTEM_PROMPT, CV_USER_PROMPT, cvSchema } from './cv-schema.ts';

const MODEL = 'claude-opus-5-5';
/** 10 MB PDF; Base64 ist ein Drittel größer */
const MAX_PDF_BYTES = 10 * 1024 * 1024;

function parsePdf(body: unknown) {
  const raw = (body as { pdf?: unknown } | null)?.pdf;
  if (typeof raw !== 'string' || raw === '') return fail(400, 'bad-request');
  const pdf = raw.replace(/\s/g, '');
  if ((pdf.length * 3) / 4 > MAX_PDF_BYTES) return fail(413, 'too-large');
  // Jedes PDF beginnt mit „%PDF-“, Base64 davon mit „JVBERi0“
  if (!pdf.startsWith('JVBERi0')) return fail(400, 'bad-request');
  return pdf;
}

serveAi('Lebenslauf-Import', parsePdf, async (pdf, client) => {
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
});
