// What makes a failed e2e attempt the machine's fault rather than the code's, kept apart from the
// fixtures and the reporter that act on it so the decision is unit-tested (faults.test.ts).

/**
 * Chromium aborts every in-flight request, loopback included, when the host's network configuration
 * changes, so a page that loses its Vite module requests this way never loaded through no fault of the
 * code under test (ISS-81796).
 */
export const NETWORK_CHANGED = 'net::ERR_NETWORK_CHANGED';

/** The name of the attachment a failed attempt carries when the machine, not the code, failed it. */
export const INFRA_ATTACHMENT = 'infra fault';

/** What a page saw while its test ran, as far as deciding whether its failure was the machine's. */
export interface PageFaults {
  /** The page, its context or its browser closed or crashed while the test was running. */
  closedUnder: boolean;
  /** A request failed with {@link NETWORK_CHANGED} while the test was running. */
  networkChanged: boolean;
}

export function isNetworkChanged(errorText: string | undefined): boolean {
  return errorText !== undefined && errorText.includes(NETWORK_CHANGED);
}

/**
 * Why a failed attempt earns its one retry, or undefined when it failed on its own. A closed browser
 * is retried (ISS-74270); a network change is retried and, when the retry meets it too, an infra fault.
 */
export function retryReason(faults: PageFaults): string | undefined {
  if (faults.networkChanged) return infraReason(faults);
  if (faults.closedUnder) return 'a page or browser closed under it';
  return undefined;
}

/** The infrastructure fault a failed attempt shows, or undefined when it shows none. */
export function infraReason(faults: PageFaults): string | undefined {
  return faults.networkChanged ? 'Chromium aborted its requests on a host network change (' + NETWORK_CHANGED + ')' : undefined;
}

/** A test at the end of the run: its outcome and the infra fault its last attempt carries, if any. */
export interface FinalTest {
  title: string;
  outcome: 'skipped' | 'expected' | 'unexpected' | 'flaky';
  infra: string | undefined;
}

/**
 * The lines that call the run an infrastructure fault: one per failed test, when every failed test's
 * last attempt failed on the machine. Undefined when none failed or any one failed on its own, which
 * keeps the run red.
 */
export function infraVerdict(tests: FinalTest[]): string[] | undefined {
  const failed = tests.filter((t) => t.outcome === 'unexpected');
  if (failed.length === 0 || failed.some((t) => t.infra === undefined)) return undefined;
  return failed.map((t) => t.title + ': ' + String(t.infra));
}
