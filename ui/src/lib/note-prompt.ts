// The nightly note prompt the release ships (behaviors/prompts/nightly-note.md), which stands until the
// circle adopts a suggestion (ISS-51009). The build inlines it, so a new suggestion starts from the
// exact text the agent is given.
import text from '../../../behaviors/prompts/nightly-note.md?raw';

export const releasePrompt: string = text.trim();
