import {
  draftSchema,
  LETTER_SYSTEM_PROMPT,
  letterInputSchema,
  letterUserPrompt,
  sectionSchema,
} from '@jobpilot-org/shared-ai/features/cover-letter';
import { runAnthropic } from '@jobpilot-org/shared-ai/providers/anthropic';

import { fail, json, serveAi } from '../_shared/ai-request.ts';

function parseInput(body: unknown) {
  if (JSON.stringify(body ?? null).length > 300_000) return fail(413, 'too-large');
  const input = letterInputSchema.safeParse(body);
  if (!input.success) return fail(400, 'bad-request');
  if (input.data.mode === 'section' && !input.data.section) return fail(400, 'bad-request');
  return input.data;
}

serveAi('Anschreiben', parseInput, async (input, client) => {
  const { output, model } = await runAnthropic(client, {
    system: LETTER_SYSTEM_PROMPT,
    user: letterUserPrompt(input),
    schema: input.mode === 'draft' ? draftSchema : sectionSchema,
    maxTokens: 8000,
    effort: 'medium',
  });
  return json(200, { ...output, model });
});
