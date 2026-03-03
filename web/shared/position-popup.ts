/**
 * Shared popup positioning utility.
 *
 * Prevents popups from being clipped by viewport edges.
 * Algorithm: default below-left, flip above if bottom overflows,
 * shift horizontally if right/left overflows.
 */

export interface AnchorCoords {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

export interface PositionPopupOptions {
  /** Vertical gap between anchor and popup (default 4) */
  gap?: number;
  /** Minimum margin from viewport edges (default 8) */
  margin?: number;
}

/**
 * Position a popup element relative to an anchor, ensuring it stays
 * within the viewport. The popup must be visible (display: block/flex)
 * before calling so getBoundingClientRect() returns accurate dimensions.
 *
 * This function runs synchronously — no requestAnimationFrame — so
 * blur-commit handlers that check `display !== 'none'` are not affected.
 */
export function positionPopup(
  popup: HTMLElement,
  anchor: AnchorCoords,
  options?: PositionPopupOptions
): void {
  const gap = options?.gap ?? 4;
  const margin = options?.margin ?? 8;

  const vw = window.innerWidth;
  const vh = window.innerHeight;

  // Measure popup dimensions (must already be display: block/flex)
  const rect = popup.getBoundingClientRect();
  const pw = rect.width;
  const ph = rect.height;

  // --- Vertical positioning (flip if needed) ---
  let top: number;
  const spaceBelow = vh - anchor.bottom - gap;
  const spaceAbove = anchor.top - gap;

  if (ph <= spaceBelow - margin) {
    // Fits below — default
    top = anchor.bottom + gap;
  } else if (ph <= spaceAbove - margin) {
    // Fits above — flip
    top = anchor.top - gap - ph;
  } else {
    // Doesn't fit either way — pin to side with more room
    if (spaceBelow >= spaceAbove) {
      top = anchor.bottom + gap;
    } else {
      top = anchor.top - gap - ph;
    }
  }

  // Clamp vertical to viewport
  top = Math.max(margin, Math.min(top, vh - ph - margin));

  // --- Horizontal positioning (shift if needed) ---
  let left = anchor.left;

  // Shift left if overflowing right edge
  if (left + pw > vw - margin) {
    left = vw - margin - pw;
  }

  // Clamp to left margin
  if (left < margin) {
    left = margin;
  }

  popup.style.top = `${top}px`;
  popup.style.left = `${left}px`;
}
