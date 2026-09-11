// Lets Escape bubble past ProseMirror's own keydown handling instead of letting PM swallow it.
//
// The bug this fixes: prosemirror-view's `captureKeyDown` (its internal, non-overridable
// keymap) returns `true` unconditionally for Escape (keyCode 27) -- see `editHandlers.keydown`
// in prosemirror-view, which calls `event.preventDefault()` whenever `captureKeyDown` (or any
// `handleKeyDown` prop) returns true. That means every Escape keydown with focus in this editor
// arrives at `web/shared/escape-ladder.ts`'s document-level bubble listener with
// `event.defaultPrevented === true`, which that listener reads as "an element already dismissed
// itself" and never calls `dismissTopLayer()` -- so Focus Mode, the find bar, and every native
// escape rung silently stop working whenever focus is in Milkdown.
//
// The fix relies on prosemirror-view's own event-wiring order (see `initInput` in
// prosemirror-view): the DOM `keydown` listener it installs on `view.dom` first calls
// `runCustomHandler`, which invokes any `handleDOMEvents.keydown` prop; if that returns a
// truthy value, `editHandlers.keydown` (the handler that calls `captureKeyDown` and
// `preventDefault()`) never runs at all. Returning `true` here -- without calling
// `stopPropagation()` -- claims the event ahead of PM's own handling while still letting it
// bubble up to `document` for the escape ladder to see with `defaultPrevented === false`.
//
// CodeMirror's counterpart to this fix is `defaultKeymap.filter((k) => k.key !== 'Escape')` in
// `codemirror/src/main.ts` -- CodeMirror lets a keymap entry simply not exist, so there's
// nothing to intercept there. ProseMirror has no such filter for its internal capture keymap,
// hence this plugin.
//
// Not affected by escape-ladder.ts's own preventDefault() (t-784ff3aa fix round): that shared
// listener now calls `event.preventDefault()` itself, unconditionally, the moment it starts
// handling a non-composing Escape -- but only AFTER it runs, i.e. after this plugin has already
// done its job of keeping PM's own internal `captureKeyDown` from calling `preventDefault()`
// TOO EARLY (before the ladder listener gets a chance to read `event.defaultPrevented` and
// decide). Both facts are about the same method call on the same event, at two different points
// in its bubble-phase lifetime, for two different reasons -- this plugin stops PM's premature
// call; the ladder listener's own later, deliberate call is what actually stops WebKit's default
// handling. Nothing here needs to change for that.
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';

export function buildEscapePassthroughPlugin(): Plugin {
  return new Plugin({
    key: new PluginKey('escape-passthrough'),
    props: {
      handleDOMEvents: {
        keydown(_view, event) {
          if (event.key !== 'Escape' || event.isComposing || event.keyCode === 229) return false;
          return true; // claims the event ahead of PM's own preventDefault(), without stopping propagation
        },
      },
    },
  });
}

export const escapePassthroughPlugin = $prose(buildEscapePassthroughPlugin);
