import {
  FIT_SYSTEM_PROMPT,
  fitInputSchema,
  fitSchema,
  fitUserPrompt,
} from '@jobpilot-org/shared-ai/features/job-fit';
import { runAnthropic } from '@jobpilot-org/shared-ai/providers/anthropic';

import { fail, json, serveAi } from '../_shared/ai-request.ts';

function parseInput(body: unknown) {
  if (JSON.stringify(body ?? null).length > 250_000) return fail(413, 'too-large');
  const input = fitInputSchema.safeParse(body);
  return input.success ? input.data : fail(400, 'bad-request');
}

serveAi('Passung', parseInput, async (input, client) => {
  const { output, model } = await runAnthropic(client, {
    system: FIT_SYSTEM_PROMPT,
    user: fitUserPrompt(input),
    schema: fitSchema,
    maxTokens: 8000,
    effort: 'medium',
  });
  return json(200, { fit: output, model });
});
