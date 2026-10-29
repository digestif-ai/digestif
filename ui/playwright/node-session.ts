// Against a running node (DIGESTIF_NODE), the suite needs what a member gets from `digestif open`: the
// session cookie the one-time launch link sets. Cookies are scoped to a host and not a port, so the
// cookie the node sets on 127.0.0.1 rides along on vite's 127.0.0.1 and through its proxy.
import { request } from '@playwright/test';

export const NODE_STATE = 'playwright/.auth/node.json';

export default async function globalSetup(): Promise<void> {
  const launch = process.env['DIGESTIF_NODE_LAUNCH'];
  if (launch === undefined) throw new Error('DIGESTIF_NODE_LAUNCH names no launch link');
  const context = await request.newContext();
  const response = await context.get(launch, { maxRedirects: 0 });
  if (response.status() !== 303) throw new Error('the launch link answered ' + String(response.status()));
  await context.storageState({ path: NODE_STATE });
  await context.dispose();
}
