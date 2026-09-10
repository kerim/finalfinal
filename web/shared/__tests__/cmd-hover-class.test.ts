// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CMD_HELD_CLASS, installCmdHeldTracking } from '../cmd-hover-class';

describe('cmd-held tracking', () => {
  let uninstall: () => void;
  beforeEach(() => {
    document.body.className = '';
    uninstall = installCmdHeldTracking();
  });
  afterEach(() => {
    uninstall();
    document.body.className = '';
  });

  it('adds the class on a Meta keydown', () => {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Meta', metaKey: true }));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(true);
  });
  it('removes the class on keyup', () => {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Meta', metaKey: true }));
    document.dispatchEvent(new KeyboardEvent('keyup', { key: 'Meta', metaKey: false }));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(false);
  });
  it('self-heals from a missed keyup via mousemove', () => {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Meta', metaKey: true }));
    document.dispatchEvent(new MouseEvent('mousemove', { metaKey: false }));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(false);
  });
  it('picks up meta already held on mousemove without a prior keydown', () => {
    document.dispatchEvent(new MouseEvent('mousemove', { metaKey: true }));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(true);
  });
  it('clears the class when the window loses focus', () => {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Meta', metaKey: true }));
    window.dispatchEvent(new Event('blur'));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(false);
  });
  it('clears the class when the document becomes hidden (visibilitychange)', () => {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Meta', metaKey: true }));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(true);
    const hiddenSpy = vi.spyOn(document, 'hidden', 'get').mockReturnValue(true);
    document.dispatchEvent(new Event('visibilitychange'));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(false);
    hiddenSpy.mockRestore();
  });
  it('keeps the class on a non-Meta keyup while ⌘ is still held', () => {
    // Regression pin for the `if (!e.metaKey)` check in onKeyUp: typing a letter while ⌘ is
    // held fires a keyup for that letter with metaKey still true (⌘ itself was never
    // released), and must NOT clear the hint class.
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Meta', metaKey: true }));
    document.dispatchEvent(new KeyboardEvent('keyup', { key: 'a', metaKey: true }));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(true);
  });
  it('stops tracking after uninstall', () => {
    uninstall();
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Meta', metaKey: true }));
    expect(document.body.classList.contains(CMD_HELD_CLASS)).toBe(false);
    uninstall = () => {};
  });
});
