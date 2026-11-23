import {
  CV_SYSTEM_PROMPT,
  CV_USER_PROMPT,
  cvSchema,
} from '@jobpilot-org/shared-ai/features/cv-import';
import { runAnthropic } from '@jobpilot-org/shared-ai/providers/anthropic';

import { fail, json, serveAi } from '../_shared/ai-request.ts';

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
  const { output } = await runAnthropic(client, {
    system: CV_SYSTEM_PROMPT,
    user: CV_USER_PROMPT,
    schema: cvSchema,
    maxTokens: 16000,
    effort: 'medium',
    pdf,
  });
  return json(200, { profile: output });
});
