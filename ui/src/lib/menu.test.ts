import { describe, expect, it } from 'vitest';
import { menuKeyAction, menuSections, placeMenu, triggerKeyAction, typeahead } from './menu.ts';

describe('menuSections', () => {
  it('groups acts by section in first-seen order and moves danger acts to a red last section', () => {
    const sections = menuSections([
      { label: 'Approve', section: 'Note' },
      { label: 'Dismiss', danger: true },
      { label: 'Pause', section: 'Agent' },
      { label: 'Edit', section: 'Note' }
    ]);
    expect(sections.map((s) => [s.label, s.danger, s.items.map((i) => i.label)])).toEqual([
      ['Note', false, ['Approve', 'Edit']],
      ['Agent', false, ['Pause']],
      [undefined, true, ['Dismiss']]
    ]);
  });

  it('keeps acts with no section in one unlabeled group', () => {
    const acts: { label: string; section?: string }[] = [{ label: 'A' }, { label: 'B' }];
    expect(menuSections(acts)).toEqual([{ label: undefined, danger: false, items: acts }]);
  });

  it('is empty for no acts', () => {
    expect(menuSections([])).toEqual([]);
  });
});

describe('keyboard', () => {
  const labels = ['Approve', 'Edit', 'Dismiss'];

  it('opens on the first item for Enter, Space and ArrowDown, on the last for ArrowUp', () => {
    expect(triggerKeyAction('Enter')).toEqual({ kind: 'open', focus: 'first' });
    expect(triggerKeyAction(' ')).toEqual({ kind: 'open', focus: 'first' });
    expect(triggerKeyAction('ArrowDown')).toEqual({ kind: 'open', focus: 'first' });
    expect(triggerKeyAction('ArrowUp')).toEqual({ kind: 'open', focus: 'last' });
    expect(triggerKeyAction('a')).toEqual({ kind: 'none' });
  });

  it('moves and wraps with the arrows, jumps with Home and End', () => {
    expect(menuKeyAction('ArrowDown', -1, labels)).toEqual({ kind: 'focus', index: 0 });
    expect(menuKeyAction('ArrowDown', 2, labels)).toEqual({ kind: 'focus', index: 0 });
    expect(menuKeyAction('ArrowUp', 0, labels)).toEqual({ kind: 'focus', index: 2 });
    expect(menuKeyAction('Home', 2, labels)).toEqual({ kind: 'focus', index: 0 });
    expect(menuKeyAction('End', 0, labels)).toEqual({ kind: 'focus', index: 2 });
  });

  it('closes on Escape with focus back on the button, and on Tab without it', () => {
    expect(menuKeyAction('Escape', 0, labels)).toEqual({ kind: 'close', refocus: true });
    expect(menuKeyAction('Tab', 0, labels)).toEqual({ kind: 'close', refocus: false });
  });

  it('jumps to the next item starting with a typed character, wrapping', () => {
    expect(menuKeyAction('d', 0, labels)).toEqual({ kind: 'focus', index: 2 });
    expect(typeahead('a', 1, labels)).toBe(0);
    expect(menuKeyAction('z', 0, labels)).toEqual({ kind: 'none' });
  });
});

describe('placeMenu', () => {
  const viewport = { width: 1200, height: 800 };
  const menu = { width: 272, height: 150 };

  it('sits under the button, right-aligned with it', () => {
    expect(placeMenu({ top: 20, left: 1000, bottom: 64, right: 1100 }, menu, viewport)).toEqual({ top: 70, left: 828 });
  });

  it('stays on screen near the left edge', () => {
    expect(placeMenu({ top: 20, left: 0, bottom: 64, right: 100 }, menu, viewport).left).toBe(8);
  });

  it('flips above the button when it would run off the bottom', () => {
    expect(placeMenu({ top: 700, left: 1000, bottom: 744, right: 1100 }, menu, viewport).top).toBe(544);
  });

  it('spans the screen on a phone', () => {
    expect(placeMenu({ top: 20, left: 300, bottom: 64, right: 380 }, menu, { width: 390, height: 800 })).toEqual({
      top: 70,
      left: 8,
      width: 374
    });
  });
});
