/**
 * Cursor Mapping Utilities
 * Converts between text offsets (ProseMirror) and markdown offsets (CodeMirror)
 */

/**
 * Convert text offset to markdown offset
 * Accounts for inline syntax: **bold**, *italic*, `code`, [links](url)
 */
export function textToMdOffset(markdownLine: string, textOffset: number): number {
  let mdPos = 0;
  let textPos = 0;

  while (mdPos < markdownLine.length && textPos < textOffset) {
    const remaining = markdownLine.slice(mdPos);

    // Bold **text** or __text__
    const boldMatch = remaining.match(/^(\*\*|__)([^*_]+)\1/);
    if (boldMatch) {
      const syntaxLen = boldMatch[1].length; // 2
      const contentLen = boldMatch[2].length;
      const charsNeeded = textOffset - textPos;

      if (charsNeeded <= contentLen) {
        return mdPos + syntaxLen + charsNeeded;
      }
      mdPos += syntaxLen * 2 + contentLen;
      textPos += contentLen;
      continue;
    }

    // Italic *text* or _text_
    const italicMatch = remaining.match(/^(\*|_)([^*_]+)\1/);
    if (italicMatch) {
      const syntaxLen = 1;
      const contentLen = italicMatch[2].length;
      const charsNeeded = textOffset - textPos;

      if (charsNeeded <= contentLen) {
        return mdPos + syntaxLen + charsNeeded;
      }
      mdPos += syntaxLen * 2 + contentLen;
      textPos += contentLen;
      continue;
    }

    // Code `text`
    const codeMatch = remaining.match(/^`([^`]+)`/);
    if (codeMatch) {
      const contentLen = codeMatch[1].length;
      const charsNeeded = textOffset - textPos;

      if (charsNeeded <= contentLen) {
        return mdPos + 1 + charsNeeded;
      }
      mdPos += 2 + contentLen;
      textPos += contentLen;
      continue;
    }

    // Link [text](url)
    const linkMatch = remaining.match(/^\[([^\]]+)\]\([^)]+\)/);
    if (linkMatch) {
      const textLen = linkMatch[1].length;
      const charsNeeded = textOffset - textPos;

      if (charsNeeded <= textLen) {
        return mdPos + 1 + charsNeeded; // +1 for opening [
      }
      mdPos += linkMatch[0].length;
      textPos += textLen;
      continue;
    }

    // Escaped character \*
    if (remaining.startsWith('\\') && remaining.length > 1) {
      mdPos += 2;
      textPos += 1;
      continue;
    }

    // Regular character
    mdPos++;
    textPos++;
  }

  return mdPos;
}

/**
 * Convert markdown offset to text offset
 * Inverse of textToMdOffset
 */
export function mdToTextOffset(markdownLine: string, mdOffset: number): number {
  let mdPos = 0;
  let textPos = 0;

  while (mdPos < mdOffset && mdPos < markdownLine.length) {
    const remaining = markdownLine.slice(mdPos);

    // Bold **text** or __text__
    const boldMatch = remaining.match(/^(\*\*|__)([^*_]+)\1/);
    if (boldMatch) {
      const syntaxLen = 2;
      const fullLen = boldMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        // Cursor is inside this bold section
        const posInMatch = mdOffset - mdPos;
        if (posInMatch <= syntaxLen) return textPos;
        if (posInMatch > syntaxLen + boldMatch[2].length) return textPos + boldMatch[2].length;
        return textPos + posInMatch - syntaxLen;
      }
      mdPos += fullLen;
      textPos += boldMatch[2].length;
      continue;
    }

    // Italic *text* or _text_
    const italicMatch = remaining.match(/^(\*|_)([^*_]+)\1/);
    if (italicMatch) {
      const fullLen = italicMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch < 1) return textPos;
        if (posInMatch > 1 + italicMatch[2].length) return textPos + italicMatch[2].length;
        return textPos + posInMatch - 1;
      }
      mdPos += fullLen;
      textPos += italicMatch[2].length;
      continue;
    }

    // Code `text`
    const codeMatch = remaining.match(/^`([^`]+)`/);
    if (codeMatch) {
      const fullLen = codeMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch < 1) return textPos;
        if (posInMatch > 1 + codeMatch[1].length) return textPos + codeMatch[1].length;
        return textPos + posInMatch - 1;
      }
      mdPos += fullLen;
      textPos += codeMatch[1].length;
      continue;
    }

    // Link [text](url)
    const linkMatch = remaining.match(/^\[([^\]]+)\]\([^)]+\)/);
    if (linkMatch) {
      const fullLen = linkMatch[0].length;
      const textLen = linkMatch[1].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch < 1) return textPos;
        if (posInMatch > 1 + textLen) return textPos + textLen;
        return textPos + Math.min(posInMatch - 1, textLen);
      }
      mdPos += fullLen;
      textPos += textLen;
      continue;
    }

    // Escaped character
    if (remaining.startsWith('\\') && remaining.length > 1) {
      if (mdOffset === mdPos) return textPos;
      mdPos += 2;
      textPos += 1;
      continue;
    }

    // Regular character
    mdPos++;
    textPos++;
  }

  return textPos;
}
