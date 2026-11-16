// @vitest-environment jsdom
import { Schema } from '@milkdown/kit/prose/model';
import { EditorState, TextSelection } from '@milkdown/kit/prose/state';
import { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { logReplacementResult, logReplacementTarget, logUnusualInput } from '../autocorrect-diag';
import { setTraceTyping } from '../typing-trace';

// t-561c4083: the autocorrect diagnostics post nothing at all with tracing off, and no document text with it on.
const schema = new Schema({
  nodes: { doc: { content: 'paragraph+' }, paragraph: { content: 'text*', toDOM: () => ['p', 0] }, text: {} },
});
const WORDS = ['Hello', 'Zyxquorbit', 'world', 'Plinthwarg', 'pasted', 'sentence'];

// The document is the one paragraph "Hello Zyxquorbit world": positions 1-6 Hello, 6-7 a space, 7-17 Zyxquorbit,
// 17-18 a space, 18-23 world. The paragraph node adds 2, so the document is 24 long.
function makeView(): EditorView {
  const doc = schema.node('doc', null, [schema.node('paragraph', null, [schema.text('Hello Zyxquorbit world')])]);
  let state = EditorState.create({ doc });
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, 7, 17)));
  return new EditorView(document.createElement('div'), { state });
}

function pasteEvent(
  getTargetRanges: () => unknown[] = () => [],
  getData: () => string = () => 'Plinthwarg pasted sentence.'
): InputEvent {
  return {
    inputType: 'insertFromPaste',
    data: null,
    dataTransfer: { getData },
    getTargetRanges,
  } as unknown as InputEvent;
}

describe('autocorrect-diag privacy (t-561c4083)', () => {
  let post: ReturnType<typeof vi.fn>;
  let consoleLog: ReturnType<typeof vi.spyOn>;

  const messages = () => post.mock.calls.map((call) => String(call[0].message));

  beforeEach(() => {
    post = vi.fn();
    (window as any).webkit = { messageHandlers: { errorHandler: { postMessage: post } } };
    consoleLog = vi.spyOn(console, 'log').mockImplementation(() => {});
  });

  afterEach(() => {
    setTraceTyping(false);
    delete (window as any).webkit;
    consoleLog.mockRestore();
  });

  it('posts nothing and reads nothing while tracing is off', () => {
    setTraceTyping(false);
    const view = makeView();
    const ranges = vi.fn(() => []);
    const getData = vi.fn(() => 'Plinthwarg pasted sentence.');
    logUnusualInput(view, pasteEvent(ranges, getData));
    logReplacementTarget(view, 'selection', 7, 17, 'Plinthwarg');
    logReplacementResult(view, 7, 'Plinthwarg');
    expect(post).not.toHaveBeenCalled();
    expect(consoleLog).not.toHaveBeenCalled();
    expect(ranges).not.toHaveBeenCalled();
    expect(getData).not.toHaveBeenCalled();
  });

  it('posts lengths, kinds and positions but no document text while tracing is on', () => {
    setTraceTyping(true);
    const view = makeView();
    logUnusualInput(view, pasteEvent());
    logReplacementTarget(view, 'selection', 7, 17, 'Plinthwarg');
    logReplacementResult(view, 7, 'Plinthwarg');
    expect(post).toHaveBeenCalledTimes(3);
    const [input, target, result] = messages();
    expect(input).toContain('type=insertFromPaste');
    expect(input).toContain('dataLen=27');
    expect(input).toContain('dataNewlines=0');
    expect(target).toContain('target=7-17');
    expect(result).toContain('replaced result=7-17 len=10 kind=word');
    for (const message of messages()) for (const word of WORDS) expect(message).not.toContain(word);
  });

  it('says len= and kind= correctly for a word, a space, a mixed span, an empty span and a span outside the document', () => {
    setTraceTyping(true);
    const view = makeView();
    logReplacementTarget(view, 'selection', 7, 17, 'Plinthwarg'); // Zyxquorbit, replaced by a word
    logReplacementTarget(view, 'selection', 6, 7, ' '); // the space, replaced by a space
    logReplacementTarget(view, 'selection', 1, 8, 'a b'); // "Hello Z", replaced by a mixed text
    logReplacementTarget(view, 'selection', 7, 7, ''); // nothing, replaced by nothing
    logReplacementTarget(view, 'selection', 30, 40, 'x'); // past the end of the 24-long document
    const [word, space, mixed, empty, outside] = messages();
    expect(word).toContain('replacing=7-17 len=10 kind=word');
    expect(word).toContain('withLen=10 withKind=word');
    expect(space).toContain('replacing=6-7 len=1 kind=space');
    expect(space).toContain('withLen=1 withKind=space');
    expect(mixed).toContain('replacing=1-8 len=7 kind=mixed');
    expect(mixed).toContain('withLen=3 withKind=mixed');
    expect(empty).toContain('replacing=7-7 len=0 kind=empty');
    expect(empty).toContain('withLen=0 withKind=empty');
    expect(outside).toContain('replacing=30-40 out-of-range docSize=24');
    // The caret span is the selection 7-17 in every line.
    for (const message of messages()) expect(message).toContain('caret=7-17 len=10 kind=word');
    for (const message of messages()) for (const word of WORDS) expect(message).not.toContain(word);
  });
});
