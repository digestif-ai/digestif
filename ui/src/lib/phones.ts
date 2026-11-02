import type { Device } from '#generated/com-bryzek-digestif-node.ts';

/** A member's devices are this machine, admitted at the join, then each phone added after it. */
export function phonesOf(devices: Device[]): Device[] {
  return devices
    .filter((d) => d.role === 'device')
    .sort((a, b) => a.admitted_at.localeCompare(b.admitted_at))
    .slice(1);
}
