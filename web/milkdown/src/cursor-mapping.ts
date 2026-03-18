/**
 * Cursor Mapping Utilities
 * Converts between text offsets (ProseMirror) and markdown offsets (CodeMirror)
 */

/**
 * Calculate visible text length of a markdown string
 * Uses mdToTextOffset to get accurate count after stripping all formatting
 */
function getVisibleTextLength(markdown: string): number {
  return mdToTextOffsetInternal(markdown, markdown.length);
}

/**
 * Internal mdToTextOffset that can be called before the export is defined
 */
function mdToTextOffsetInternal(markdownLine: string, mdOffset: number): number {
  let mdPos = 0;
  let textPos = 0;

  while (mdPos < mdOffset && mdPos < markdownLine.length) {
    const remaining = markdownLine.slice(mdPos);

    // Bold **text** - must check before italic *text*
    const boldMatch = remaining.match(/^(\*\*)(.+?)\1(?!\*)/);
    if (boldMatch) {
      const syntaxLen = 2;
      const content = boldMatch[2];
      const fullLen = boldMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch <= syntaxLen) return textPos;
        const contentTextLen = getVisibleTextLength(content);
        if (posInMatch > syntaxLen + content.length) return textPos + contentTextLen;
        // Recursively map position within content
        return textPos + mdToTextOffsetInternal(content, posInMatch - syntaxLen);
      }
      mdPos += fullLen;
      textPos += getVisibleTextLength(content);
      continue;
    }

    // Bold __text__
    const boldAltMatch = remaining.match(/^(__)(.+?)\1(?!_)/);
    if (boldAltMatch) {
      const syntaxLen = 2;
      const content = boldAltMatch[2];
      const fullLen = boldAltMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch <= syntaxLen) return textPos;
        const contentTextLen = getVisibleTextLength(content);
        if (posInMatch > syntaxLen + content.length) return textPos + contentTextLen;
        return textPos + mdToTextOffsetInternal(content, posInMatch - syntaxLen);
      }
      mdPos += fullLen;
      textPos += getVisibleTextLength(content);
      continue;
    }

    // Italic *text* - only try if NOT starting with ** (prevents matching inside bold)
    if (!remaining.startsWith('**')) {
      const italicMatch = remaining.match(/^\*([^*]+)\*/);
      if (italicMatch) {
        const content = italicMatch[1];
        const fullLen = italicMatch[0].length;

        if (mdOffset < mdPos + fullLen) {
          const posInMatch = mdOffset - mdPos;
          if (posInMatch < 1) return textPos;
          if (posInMatch > 1 + content.length) return textPos + content.length;
          return textPos + posInMatch - 1;
        }
        mdPos += fullLen;
        textPos += content.length;
        continue;
      }
    }

    // Italic _text_
    if (!remaining.startsWith('__')) {
      const italicAltMatch = remaining.match(/^_([^_]+)_/);
      if (italicAltMatch) {
        const content = italicAltMatch[1];
        const fullLen = italicAltMatch[0].length;

        if (mdOffset < mdPos + fullLen) {
          const posInMatch = mdOffset - mdPos;
          if (posInMatch < 1) return textPos;
          if (posInMatch > 1 + content.length) return textPos + content.length;
          return textPos + posInMatch - 1;
        }
        mdPos += fullLen;
        textPos += content.length;
        continue;
      }
    }

    // Code `text`
    const codeMatch = remaining.match(/^`([^`]+)`/);
    if (codeMatch) {
      const content = codeMatch[1];
      const fullLen = codeMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch < 1) return textPos;
        if (posInMatch > 1 + content.length) return textPos + content.length;
        return textPos + posInMatch - 1;
      }
      mdPos += fullLen;
      textPos += content.length;
      continue;
    }

    // Link [text](url)
    const linkMatch = remaining.match(/^\[([^\]]+)\]\([^)]+\)/);
    if (linkMatch) {
      const textLen = linkMatch[1].length;
      const fullLen = linkMatch[0].length;

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

    // Image ![alt](url)
    const imageMatch = remaining.match(/^!\[([^\]]*)\]\([^)]+\)/);
    if (imageMatch) {
      const altLen = imageMatch[1].length;
      const fullLen = imageMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch < 2) return textPos;
        if (posInMatch > 2 + altLen) return textPos + altLen;
        return textPos + Math.min(posInMatch - 2, altLen);
      }
      mdPos += fullLen;
      textPos += altLen;
      continue;
    }

    // Strikethrough ~~text~~
    const strikeMatch = remaining.match(/^~~(.+?)~~/);
    if (strikeMatch) {
      const content = strikeMatch[1];
      const fullLen = strikeMatch[0].length;

      if (mdOffset < mdPos + fullLen) {
        const posInMatch = mdOffset - mdPos;
        if (posInMatch < 2) return textPos;
        if (posInMatch > 2 + content.length) return textPos + content.length;
        return textPos + posInMatch - 2;
      }
      mdPos += fullLen;
      textPos += content.length;
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

/**
 * Convert text offset to markdown offset
 * Accounts for inline syntax: **bold**, *italic*, `code`, [links](url)
 * Handles nested formatting by recursively processing content
 */
export function textToMdOffset(markdownLine: string, textOffset: number): number {
  let mdPos = 0;
  let textPos = 0;

  while (mdPos < markdownLine.length && textPos < textOffset) {
    const remaining = markdownLine.slice(mdPos);

    // Bold **text** - check first before italic
    const boldMatch = remaining.match(/^(\*\*)(.+?)\1(?!\*)/);
    if (boldMatch) {
      const syntaxLen = 2;
      const content = boldMatch[2];
      const contentTextLen = getVisibleTextLength(content);
      const charsNeeded = textOffset - textPos;

      if (charsNeeded < contentTextLen) {
        // Recursively map position within content
        return mdPos + syntaxLen + textToMdOffset(content, charsNeeded);
      }
      if (charsNeeded === contentTextLen) {
        // At boundary - end of content, before closing syntax
        return mdPos + syntaxLen + content.length;
      }
      mdPos += syntaxLen * 2 + content.length;
      textPos += contentTextLen;
      continue;
    }

    // Bold __text__
    const boldAltMatch = remaining.match(/^(__)(.+?)\1(?!_)/);
    if (boldAltMatch) {
      const syntaxLen = 2;
      const content = boldAltMatch[2];
      const contentTextLen = getVisibleTextLength(content);
      const charsNeeded = textOffset - textPos;

      if (charsNeeded < contentTextLen) {
        return mdPos + syntaxLen + textToMdOffset(content, charsNeeded);
      }
      if (charsNeeded === contentTextLen) {
        return mdPos + syntaxLen + content.length;
      }
      mdPos += syntaxLen * 2 + content.length;
      textPos += contentTextLen;
      continue;
    }

    // Italic *text* - only try if NOT starting with ** (prevents matching inside bold)
    if (!remaining.startsWith('**')) {
      const italicMatch = remaining.match(/^\*([^*]+)\*/);
      if (italicMatch) {
        const syntaxLen = 1;
        const content = italicMatch[1];
        const charsNeeded = textOffset - textPos;

        if (charsNeeded < content.length) {
          return mdPos + syntaxLen + charsNeeded;
        }
        if (charsNeeded === content.length) {
          return mdPos + syntaxLen + content.length;
        }
        mdPos += syntaxLen * 2 + content.length;
        textPos += content.length;
        continue;
      }
    }

    // Italic _text_
    if (!remaining.startsWith('__')) {
      const italicAltMatch = remaining.match(/^_([^_]+)_/);
      if (italicAltMatch) {
        const syntaxLen = 1;
        const content = italicAltMatch[1];
        const charsNeeded = textOffset - textPos;

        if (charsNeeded < content.length) {
          return mdPos + syntaxLen + charsNeeded;
        }
        if (charsNeeded === content.length) {
          return mdPos + syntaxLen + content.length;
        }
        mdPos += syntaxLen * 2 + content.length;
        textPos += content.length;
        continue;
      }
    }

    // Code `text`
    const codeMatch = remaining.match(/^`([^`]+)`/);
    if (codeMatch) {
      const content = codeMatch[1];
      const charsNeeded = textOffset - textPos;

      if (charsNeeded < content.length) {
        return mdPos + 1 + charsNeeded;
      }
      if (charsNeeded === content.length) {
        return mdPos + 1 + content.length;
      }
      mdPos += 2 + content.length;
      textPos += content.length;
      continue;
    }

    // Link [text](url)
    const linkMatch = remaining.match(/^\[([^\]]+)\]\([^)]+\)/);
    if (linkMatch) {
      const textLen = linkMatch[1].length;
      const charsNeeded = textOffset - textPos;

      if (charsNeeded < textLen) {
        return mdPos + 1 + charsNeeded;
      }
      if (charsNeeded === textLen) {
        return mdPos + 1 + textLen;
      }
      mdPos += linkMatch[0].length;
      textPos += textLen;
      continue;
    }

    // Image ![alt](url)
    const imageMatch = remaining.match(/^!\[([^\]]*)\]\([^)]+\)/);
    if (imageMatch) {
      const altLen = imageMatch[1].length;
      const charsNeeded = textOffset - textPos;

      if (charsNeeded < altLen) {
        return mdPos + 2 + charsNeeded;
      }
      if (charsNeeded === altLen) {
        return mdPos + 2 + altLen;
      }
      mdPos += imageMatch[0].length;
      textPos += altLen;
      continue;
    }

    // Strikethrough ~~text~~
    const strikeMatch = remaining.match(/^~~(.+?)~~/);
    if (strikeMatch) {
      const content = strikeMatch[1];
      const charsNeeded = textOffset - textPos;

      if (charsNeeded < content.length) {
        return mdPos + 2 + charsNeeded;
      }
      if (charsNeeded === content.length) {
        return mdPos + 2 + content.length;
      }
      mdPos += 4 + content.length;
      textPos += content.length;
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
  return mdToTextOffsetInternal(markdownLine, mdOffset);
}
