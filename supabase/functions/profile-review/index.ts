import {
  REVIEW_SYSTEM_PROMPT,
  reviewInputSchema,
  reviewSchema,
  reviewUserPrompt,
} from '@jobpilot-org/shared-ai/features/profile-review';
import { runAnthropic } from '@jobpilot-org/shared-ai/providers/anthropic';

import { fail, json, serveAi } from '../_shared/ai-request.ts';

function parseInput(body: unknown) {
  if (JSON.stringify(body ?? null).length > 200_000) return fail(413, 'too-large');
  const input = reviewInputSchema.safeParse(body);
  return input.success ? input.data : fail(400, 'bad-request');
}

serveAi('Profil-Check', parseInput, async (input, client) => {
  const { output } = await runAnthropic(client, {
    system: REVIEW_SYSTEM_PROMPT,
    user: reviewUserPrompt(input),
    schema: reviewSchema,
    maxTokens: 16000,
    effort: 'medium',
  });
  return json(200, { review: output });
});
