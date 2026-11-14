import type { Device } from '#generated/ai-digestif-digestif-node.ts';

/** A member's phones, the oldest first: the node flags each device key paired as a phone, and a
 * device with no flag (a node built before the flag) is not one. */
export function phonesOf(devices: Device[]): Device[] {
  return devices.filter((d) => d.phone === true).sort((a, b) => a.admitted_at.localeCompare(b.admitted_at));
}
