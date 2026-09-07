// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { dismissMenu, showSpellcheckMenu } from '../spellcheck-menu';
import { dismissPopover, isPopoverOpen, showProofingPopover } from '../spellcheck-popover';

// Both editors import these modules from `shared/` (see spellcheck-plugin.ts in each of
// milkdown/src and codemirror/src). This test exists so the shared implementation is
// covered once, in one place, instead of duplicated per editor.

afterEach(() => {
  dismissMenu();
  dismissPopover();
  document.body.innerHTML = '';
});

describe('shared spellcheck menu', () => {
  it('renders a .spellcheck-menu with a suggestion button, and dismissMenu removes it', () => {
    showSpellcheckMenu({
      x: 10,
      y: 20,
      word: 'teh',
      type: 'spelling',
      suggestions: ['the', 'ten'],
      onReplace: vi.fn(),
      onLearn: vi.fn(),
      onIgnore: vi.fn(),
    });

    const menu = document.querySelector('.spellcheck-menu');
    expect(menu).not.toBeNull();
    const suggestionButtons = document.querySelectorAll('.spellcheck-menu-suggestion');
    expect(suggestionButtons.length).toBe(2);
    expect(suggestionButtons[0]?.textContent).toBe('the');

    dismissMenu();
    expect(document.querySelector('.spellcheck-menu')).toBeNull();
  });
});

describe('shared proofing popover', () => {
  it('renders a .proofing-popover with a suggestion button, and dismissPopover removes it', () => {
    showProofingPopover({
      x: 10,
      y: 20,
      word: 'has',
      type: 'grammar',
      message: 'Subject-verb agreement error.',
      shortMessage: 'Agreement error',
      ruleId: 'SUBJECT_VERB_AGREEMENT',
      isPicky: false,
      suggestions: ['have'],
      onReplace: vi.fn(),
      onIgnore: vi.fn(),
      onDisableRule: vi.fn(),
    });

    expect(isPopoverOpen()).toBe(true);
    const popover = document.querySelector('.proofing-popover');
    expect(popover).not.toBeNull();
    const suggestionButtons = document.querySelectorAll('.proofing-popover-suggestion');
    expect(suggestionButtons.length).toBe(1);
    expect(suggestionButtons[0]?.textContent).toBe('have');

    dismissPopover();
    expect(isPopoverOpen()).toBe(false);
    expect(document.querySelector('.proofing-popover')).toBeNull();
  });
});
