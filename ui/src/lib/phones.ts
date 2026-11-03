import type { Device } from '#generated/com-bryzek-digestif-node.ts';

/** A member's phones, the oldest first: the node flags each device key paired as a phone. */
export function phonesOf(devices: Device[]): Device[] {
  return devices.filter((d) => d.phone).sort((a, b) => a.admitted_at.localeCompare(b.admitted_at));
}
