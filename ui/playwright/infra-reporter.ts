// Writes playwright/run.sh's verdict file when every test that failed the run failed on the machine
// (faults.ts, infraVerdict), so the shard reports an infrastructure fault rather than a red (ISS-81796).
// A run with any test that failed on its own writes nothing and stays red.
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import type { FullConfig, FullResult, Reporter, Suite } from '@playwright/test/reporter';
import { INFRA_ATTACHMENT, infraVerdict, type FinalTest } from './faults.ts';

/** Relative to the config's directory; playwright/run.sh reads it. */
export const VERDICT_FILE = 'test-results/infra-verdict.txt';

export default class InfraReporter implements Reporter {
  private file = '';
  private suite: Suite | undefined;

  onBegin(config: FullConfig, suite: Suite): void {
    this.file = resolve(dirname(config.configFile ?? '.'), VERDICT_FILE);
    rmSync(this.file, { force: true });
    this.suite = suite;
  }

  onEnd(result: FullResult): void {
    if (result.status !== 'failed' || this.suite === undefined) return;
    const verdict = infraVerdict(this.suite.allTests().map(finalTest));
    if (verdict === undefined) return;
    mkdirSync(dirname(this.file), { recursive: true });
    writeFileSync(this.file, verdict.join('\n') + '\n');
  }

  printsToStdio(): boolean {
    return false;
  }
}

function finalTest(test: Suite['tests'][number]): FinalTest {
  const last = test.results.at(-1);
  const attachment = last?.attachments.find((a) => a.name === INFRA_ATTACHMENT);
  return {
    title: test.titlePath().filter(Boolean).join(' > '),
    outcome: test.outcome(),
    infra: attachment?.body?.toString()
  };
}
