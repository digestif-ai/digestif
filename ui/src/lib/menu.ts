/**
 * The header Actions menu's pure parts, tested without a DOM: how its acts group into sections, the
 * keyboard model of a WAI-ARIA menu button (https://www.w3.org/WAI/ARIA/apg/patterns/menu-button/),
 * and where the open menu is placed.
 */

/** The fields of an act that decide its section. */
export interface Sectioned {
  /** The labeled group it belongs to ("Note"); acts with the same section sit together. */
  section?: string;
  /** What destroys or discards something: drawn red, in the unlabeled last section. */
  danger?: boolean;
}

export interface MenuSection<T> {
  /** Undefined for an unlabeled group: the red last one, or acts that name no section. */
  label: string | undefined;
  danger: boolean;
  items: T[];
}

/**
 * The acts as sections, in the order each section first appears, with every `danger` act moved to
 * one red section at the end so nothing destructive sits between ordinary acts.
 */
export function menuSections<T extends Sectioned>(actions: readonly T[]): MenuSection<T>[] {
  const sections: MenuSection<T>[] = [];
  const danger: T[] = [];
  for (const action of actions) {
    if (action.danger === true) {
      danger.push(action);
      continue;
    }
    const found = sections.find((s) => s.label === action.section);
    if (found === undefined) sections.push({ label: action.section, danger: false, items: [action] });
    else found.items.push(action);
  }
  if (danger.length > 0) sections.push({ label: undefined, danger: true, items: danger });
  return sections;
}

/** What a key pressed on the closed menu's button does. */
export type TriggerKeyAction = { kind: 'open'; focus: 'first' | 'last' } | { kind: 'none' };

/** Enter, Space and ArrowDown open the menu on its first item, ArrowUp on its last. */
export function triggerKeyAction(key: string): TriggerKeyAction {
  switch (key) {
    case 'Enter':
    case ' ':
    case 'ArrowDown':
      return { kind: 'open', focus: 'first' };
    case 'ArrowUp':
      return { kind: 'open', focus: 'last' };
    default:
      return { kind: 'none' };
  }
}

/** What a key pressed inside the open menu does. */
export type MenuKeyAction = { kind: 'focus'; index: number } | { kind: 'close'; refocus: boolean } | { kind: 'none' };

/**
 * ArrowDown and ArrowUp move and wrap, Home and End jump, a printable character moves to the next
 * item whose label starts with it, Escape closes and puts focus back on the button, and Tab closes
 * and lets focus move on.
 *
 * @param current the focused item's index, or -1 when no item has focus
 * @param labels every item's visible label, in order
 */
export function menuKeyAction(key: string, current: number, labels: readonly string[]): MenuKeyAction {
  const count = labels.length;
  if (key === 'Escape') return { kind: 'close', refocus: true };
  if (key === 'Tab') return { kind: 'close', refocus: false };
  if (count === 0) return { kind: 'none' };
  switch (key) {
    case 'ArrowDown':
      return { kind: 'focus', index: current < 0 ? 0 : (current + 1) % count };
    case 'ArrowUp':
      return { kind: 'focus', index: current < 0 ? count - 1 : (current - 1 + count) % count };
    case 'Home':
      return { kind: 'focus', index: 0 };
    case 'End':
      return { kind: 'focus', index: count - 1 };
  }
  if ([...key].length !== 1 || key.trim() === '') return { kind: 'none' };
  const index = typeahead(key, current, labels);
  return index < 0 ? { kind: 'none' } : { kind: 'focus', index };
}

/** The next item after `current`, wrapping, whose label starts with `char`; -1 when none does. */
export function typeahead(char: string, current: number, labels: readonly string[]): number {
  const wanted = char.toLocaleLowerCase();
  for (let step = 1; step <= labels.length; step++) {
    const index = (current + step + labels.length) % labels.length;
    if ((labels[index] ?? '').trim().toLocaleLowerCase().startsWith(wanted)) return index;
  }
  return -1;
}

/** Gap between the button and the menu. */
export const MENU_GAP = 6;
/** The smallest margin the menu keeps from a viewport edge. */
export const VIEWPORT_MARGIN = 8;
/** At or below this viewport width the menu spans the screen. */
export const PHONE_MAX_WIDTH = 640;

export interface Box {
  top: number;
  left: number;
  bottom: number;
  right: number;
}

export interface Size {
  width: number;
  height: number;
}

export interface Placement {
  top: number;
  left: number;
  /** Set on a phone, where the menu takes the viewport's width; otherwise the menu keeps its own. */
  width?: number;
}

/**
 * The menu is portaled to body and fixed, so no ancestor clips it. It sits under the button,
 * right-aligned with it and nudged to stay on screen, flips above when it would run off the bottom,
 * and on a phone spans the viewport less a margin each side.
 */
export function placeMenu(trigger: Box, menu: Size, viewport: Size): Placement {
  const phone = viewport.width <= PHONE_MAX_WIDTH;
  const width = phone ? viewport.width - 2 * VIEWPORT_MARGIN : menu.width;
  const maxLeft = viewport.width - width - VIEWPORT_MARGIN;
  const left = phone ? VIEWPORT_MARGIN : Math.max(VIEWPORT_MARGIN, Math.min(trigger.right - width, maxLeft));
  const below = trigger.bottom + MENU_GAP;
  const fitsBelow = below + menu.height <= viewport.height - VIEWPORT_MARGIN;
  const top = fitsBelow ? below : Math.max(VIEWPORT_MARGIN, trigger.top - MENU_GAP - menu.height);
  return phone ? { top, left, width } : { top, left };
}
