// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';
import { slashCommands as cmCommands } from '../../../codemirror/src/slash-completions';
import { slashCommands as mdCommands } from '../slash-commands';

describe('slash command descriptions', () => {
  it('match between Milkdown and CodeMirror for every shared label', () => {
    const cmByLabel = new Map(cmCommands.map((c) => [c.label, c.description]));
    const mdLabels = new Set(mdCommands.map((c) => c.label));
    const shared = mdCommands.filter((c) => cmByLabel.has(c.label));
    const cmOnly = cmCommands.filter((c) => !mdLabels.has(c.label)).map((c) => c.label);
    // /format-table is CodeMirror-only today -- CodeMirror is a text editor, so reformatting
    // a table in place is meaningful there but has no Milkdown equivalent (rich-text tables
    // are already structured). That's a feature gap, not a wording gap, and is tracked
    // separately. Pinning the asymmetry to exactly this one label means any FUTURE one-sided
    // command addition to either editor trips this assertion by name instead of silently
    // passing parity.
    expect(cmOnly).toEqual(['/format-table']);
    expect(mdCommands.filter((c) => !cmByLabel.has(c.label))).toEqual([]);
    for (const cmd of shared) {
      expect(`${cmd.label}: ${cmd.description}`).toBe(`${cmd.label}: ${cmByLabel.get(cmd.label)}`);
    }
  });
});
