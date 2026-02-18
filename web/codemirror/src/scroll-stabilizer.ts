/**
 * Scroll Stabilizer — Post-scroll measurement cycles for CM6
 *
 * After scrolling stops, triggers adaptive requestMeasure() cycles so CM6
 * can correct accumulated height estimation drift before it becomes visible
 * as blank/white gaps.
 */

import { type EditorView, ViewPlugin } from '@codemirror/view';

const DEBOUNCE_DELAY = 120; // ms after last scroll event before post-scroll measure
const HEIGHT_EPSILON = 5; // px threshold for "heights changed meaningfully"
const MAX_STABILIZE_ROUNDS = 4; // safety cap on adaptive measurement chain

export const scrollStabilizer = ViewPlugin.fromClass(
  class {
    private view: EditorView;
    private debounceTimer: ReturnType<typeof setTimeout> | null = null;
    private rafId: number | null = null;
    private lastKnownHeight: number;
    private boundOnScroll: () => void;

    constructor(view: EditorView) {
      this.view = view;
      this.lastKnownHeight = view.contentDOM.getBoundingClientRect().height;
      this.boundOnScroll = this.onScroll.bind(this);
      view.scrollDOM.addEventListener('scroll', this.boundOnScroll, { passive: true });
    }

    private onScroll() {
      if (this.rafId !== null) {
        cancelAnimationFrame(this.rafId);
        this.rafId = null;
      }

      if (this.debounceTimer !== null) {
        clearTimeout(this.debounceTimer);
      }
      this.debounceTimer = setTimeout(() => this.onScrollIdle(), DEBOUNCE_DELAY);
    }

    private onScrollIdle() {
      this.debounceTimer = null;
      this.stabilize(0);
    }

    private stabilize(round: number) {
      if (round >= MAX_STABILIZE_ROUNDS) return;

      this.view.requestMeasure({
        read: (view) => view.contentDOM.getBoundingClientRect().height,
        write: (height, _view) => {
          const delta = Math.abs(height - this.lastKnownHeight);
          this.lastKnownHeight = height;

          if (delta > HEIGHT_EPSILON) {
            this.rafId = requestAnimationFrame(() => {
              this.rafId = null;
              this.stabilize(round + 1);
            });
          }
        },
      });
    }

    destroy() {
      this.view.scrollDOM.removeEventListener('scroll', this.boundOnScroll);
      if (this.debounceTimer !== null) {
        clearTimeout(this.debounceTimer);
      }
      if (this.rafId !== null) {
        cancelAnimationFrame(this.rafId);
      }
    }
  }
);
