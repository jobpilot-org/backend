import {
  JOB_SYSTEM_PROMPT,
  jobInputSchema,
  jobSchema,
  jobUserPrompt,
  MAX_POSTING_CHARS,
} from '@jobpilot-org/shared-ai/features/job-import';
import { runAnthropic } from '@jobpilot-org/shared-ai/providers/anthropic';

import { fail, json, serveAi } from '../_shared/ai-request.ts';

function parseInput(body: unknown) {
  const posting = (body as { posting?: unknown } | null)?.posting;
  if (typeof posting === 'string' && posting.trim().length > MAX_POSTING_CHARS) {
    return fail(413, 'too-large');
  }
  const input = jobInputSchema.safeParse(body);
  return input.success ? input.data : fail(400, 'bad-request');
}

serveAi('Stellenanzeigen-Import', parseInput, async (input, client) => {
  const { output } = await runAnthropic(client, {
    system: JOB_SYSTEM_PROMPT,
    user: jobUserPrompt(input),
    schema: jobSchema,
    maxTokens: 4000,
    // Reines Herauslesen von Eckdaten – wenig Nachdenken nötig, dafür schnell
    effort: 'low',
  });
  return json(200, { job: output });
});
