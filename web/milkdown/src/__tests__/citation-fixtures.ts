// Shared fixtures for the citation tests: the 35-item library, the group builders that mirror what the Rich Text node view
// asks `formatCitation` for, a hand-written note style, and the chapter-shaped documents the timing tests use.
//
// Moved verbatim out of citeproc-format-purity.test.ts so citeproc-memo.test.ts and citation-prefill.test.ts build exactly the same
// libraries and groups instead of a copy that could drift. Not a test file (vitest only collects *.test.ts).

import { parseCitationBracket } from '../citation-types';
import type { CitationOptions, CSLItem } from '../citeproc-engine';

// ---------------------------------------------------------------------------------------------------
// Library: 35 items (a stand-in for the user's 35 sources)
// ---------------------------------------------------------------------------------------------------

export type Name = { family: string; given: string };

export function book(id: string, authors: Name[], year: number, title: string): CSLItem {
  return {
    id,
    type: 'book',
    title,
    author: authors,
    issued: { 'date-parts': [[year]] },
    publisher: 'Test Press',
    'publisher-place': 'Chicago',
  };
}

export function article(id: string, authors: Name[], year: number, title: string, journal: string): CSLItem {
  return {
    id,
    type: 'article-journal',
    title,
    author: authors,
    issued: { 'date-parts': [[year]] },
    'container-title': journal,
    volume: '12',
    issue: '3',
    page: '45-67',
  };
}

export function n(family: string, given: string): Name {
  return { family, given };
}

export const LIBRARY: CSLItem[] = [
  book('adams1999', [n('Adams', 'Robert')], 1999, 'The Long Road Home'),
  article('baker2003', [n('Baker', 'Ellen')], 2003, 'Rivers and Their Courses', 'Journal of Examples'),
  book('chen2011', [n('Chen', 'Wei')], 2011, 'Cities of Paper'),
  book('dube2007', [n('Dube', 'Anil')], 2007, 'A Grammar of Silence'),
  article('evans2015', [n('Evans', 'Dana')], 2015, 'Counting the Uncountable', 'Annals of Method'),
  book('fischer1994', [n('Fischer', 'Hans')], 1994, 'Order and Disorder'),
  book('garcia2018', [n('Garcia', 'Lucia')], 2018, 'Borders of the Mind'),
  article('haas2001', [n('Haas', 'Peter')], 2001, 'Notes on a Method', 'Journal of Examples'),
  book('ito2009', [n('Ito', 'Keiko')], 2009, 'The Weight of Water'),
  book('jones2012', [n('Jones', 'Barbara')], 2012, 'Practice and Principle'),
  article('khan2016', [n('Khan', 'Imran')], 2016, 'Markets in Motion', 'Annals of Method'),
  // Same author, same year: the style adds a year suffix (2010a, 2010b) from the library as a whole.
  book('lee2010a', [n('Lee', 'Jin')], 2010, 'Water and Stone'),
  book('lee2010b', [n('Lee', 'Jin')], 2010, 'Stone and Water'),
  book('moreau2005', [n('Moreau', 'Claire')], 2005, 'Les Chemins'),
  book('nunez2013', [n('Nunez', 'Carlos')], 2013, 'Voices from the Hill'),
  book('okafor2008', [n('Okafor', 'Ngozi')], 2008, 'Harvest Songs'),
  book('petrov2000', [n('Petrov', 'Ivan')], 2000, 'The Winter Archive'),
  article('quinn2017', [n('Quinn', 'Mary')], 2017, 'Whose Land', 'Annals of Method'),
  book('rossi1996', [n('Rossi', 'Paolo')], 1996, 'Stones of Rome'),
  book('sato2014', [n('Sato', 'Yuki')], 2014, 'Small Gods'),
  // Two authors sharing a surname, same year: the style may add given names.
  book('park2014x', [n('Park', 'Min')], 2014, 'First Light'),
  book('park2014y', [n('Park', 'Joon')], 2014, 'Last Light'),
  // Two authors sharing a surname, different years.
  book('kim2008', [n('Kim', 'Sora')], 2008, 'Paper Houses'),
  article('kim2015', [n('Kim', 'Hana')], 2015, 'Houses of Paper', 'Journal of Examples'),
  // Several authors: "et al." in the short form.
  book('smith2005', [n('Smith', 'Alice'), n('Jones', 'Bob')], 2005, 'Two Voices'),
  book('brown2012', [n('Brown', 'Carol'), n('Evans', 'Dan'), n('Haas', 'Eve')], 2012, 'Three Voices'),
  book(
    'brown2013',
    [n('Brown', 'Carol'), n('Evans', 'Dan'), n('Haas', 'Eve'), n('Ito', 'Fay'), n('Jones', 'Gus')],
    2013,
    'Five Voices'
  ),
  article('wong2010', [n('Wong', 'Mei')], 2010, 'Tides', 'Annals of Method'),
  book('xu2006', [n('Xu', 'Lin')], 2006, 'Mountain Letters'),
  book('yilmaz2019', [n('Yilmaz', 'Deniz')], 2019, 'Anatolian Winters'),
  book('zhou2004', [n('Zhou', 'Hua')], 2004, 'Ink and Silk'),
  // No author at all: the style falls back to the title.
  {
    id: 'anon2002',
    type: 'book',
    title: 'Anonymous Chronicle',
    issued: { 'date-parts': [[2002]] },
    publisher: 'Test Press',
  },
  // Editor only.
  {
    id: 'berg2009',
    type: 'book',
    title: 'Edited Volume',
    editor: [n('Berg', 'Ola')],
    issued: { 'date-parts': [[2009]] },
    publisher: 'Test Press',
  },
  book('cruz2020', [n('Cruz', 'Ana')], 2020, 'Seeds'),
  book('diaz1998', [n('Diaz', 'Luis')], 1998, 'Roads'),
];

// Unrelated to anything above (no shared author or year); adding it must not change any output.
export const UNRELATED_ITEM: CSLItem = book('zeta2021', [n('Zeta', 'Zoe')], 2021, 'An Unrelated Work');

// Shares author and year with adams1999, so adding it legitimately changes how adams1999 is shown.
export const RELATED_ITEM: CSLItem = book('adams1999b', [n('Adams', 'Robert')], 1999, 'The Longer Road Home');

// ---------------------------------------------------------------------------------------------------
// Groups, built exactly as citation-plugin.ts builds the arguments of formatCitation
// ---------------------------------------------------------------------------------------------------

export interface Group {
  label: string;
  citekeys: string[];
  options: CitationOptions;
}

// The same arguments the Rich Text NodeView passes: suppress flag for every key, locators as parsed,
// prefix as parsed (suffix is always empty from the Pandoc parser; a few groups set it by hand).
export function groupFromBracket(inner: string): Group {
  const parsed = parseCitationBracket(inner);
  return {
    label: `[${inner}]`,
    citekeys: parsed.citekeys,
    options: {
      suppressAuthors: parsed.suppressAuthor ? parsed.citekeys.map(() => true) : undefined,
      locators: parsed.locators.length > 0 ? parsed.locators : undefined,
      prefix: parsed.prefix,
      suffix: parsed.suffix,
    },
  };
}

export function handGroup(label: string, citekeys: string[], options: CitationOptions): Group {
  return { label, citekeys, options };
}

export function purityGroups(): Group[] {
  const groups: Group[] = [];
  for (const item of LIBRARY) groups.push(groupFromBracket(`@${item.id}`));
  const bracketed = [
    '@adams1999, p. 42',
    '@baker2003, pp. 45–67',
    '@lee2010a, p. 3',
    '@lee2010b, p. 3',
    '@adams1999; @baker2003',
    '@lee2010a; @lee2010b',
    '@park2014x; @park2014y',
    '@kim2008; @kim2015',
    '@smith2005; @brown2012; @brown2013',
    '@chen2011, p. 7; @dube2007, ch. 2',
    '-@adams1999',
    '-@lee2010a, p. 5',
    'see @adams1999',
    'see @adams1999, p. 4',
    '@adams1999; @nosuchkey',
  ];
  for (const inner of bracketed) groups.push(groupFromBracket(inner));
  groups.push(handGroup('[@adams1999 and passim]', ['adams1999'], { suffix: 'and passim' }));
  groups.push(
    handGroup('[compare @baker2003; @chen2011 for contrast]', ['baker2003', 'chen2011'], {
      prefix: 'compare',
      suffix: 'for contrast',
    })
  );
  return groups;
}

// A deterministic order that is neither document order nor its reverse.
export function shuffled<T>(items: T[]): T[] {
  const out = [...items];
  let seed = 12345;
  for (let i = out.length - 1; i > 0; i--) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    const j = seed % (i + 1);
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

// ---------------------------------------------------------------------------------------------------
// A hand-written note style: "ibid." for a repeat of the previous note, a short form for a later one.
// ---------------------------------------------------------------------------------------------------

export const NOTE_STYLE = `<?xml version="1.0" encoding="utf-8"?>
<style xmlns="http://purl.org/net/xbiblio/csl" class="note" version="1.0" default-locale="en-US">
  <info>
    <title>Test Note Style With Ibid</title>
    <id>http://example.com/test-note-style-ibid</id>
    <updated>2024-01-01T00:00:00+00:00</updated>
  </info>
  <macro name="author-short">
    <names variable="author">
      <name form="short"/>
    </names>
  </macro>
  <macro name="author-full">
    <names variable="author">
      <name/>
    </names>
  </macro>
  <macro name="locator-part">
    <text variable="locator" prefix=", "/>
  </macro>
  <citation>
    <layout delimiter="; " suffix=".">
      <choose>
        <if position="ibid-with-locator">
          <group>
            <text term="ibid" text-case="capitalize-first"/>
            <text macro="locator-part"/>
          </group>
        </if>
        <else-if position="ibid">
          <text term="ibid" text-case="capitalize-first"/>
        </else-if>
        <else-if position="subsequent">
          <group>
            <text macro="author-short"/>
            <text variable="title" form="short" font-style="italic" prefix=", "/>
            <text macro="locator-part"/>
          </group>
        </else-if>
        <else>
          <group>
            <text macro="author-full"/>
            <text variable="title" font-style="italic" prefix=", "/>
            <date variable="issued" prefix=" (" suffix=")">
              <date-part name="year"/>
            </date>
            <text macro="locator-part"/>
          </group>
        </else>
      </choose>
    </layout>
  </citation>
  <bibliography>
    <layout>
      <text variable="title"/>
    </layout>
  </bibliography>
</style>`;

// One chapter shaped like the plan's ARTICLE: 68 citation groups over 35 sources, 66 of them distinct
// within the chapter (two groups repeat verbatim). 28 groups carry no page number (plain, several keys,
// prefix, suppressed author); 38 carry page numbers or sections. `shift` moves every page number, so a
// chapter built with a different `shift` shares only its plain groups with the others.
export function chapterBrackets(shift: number): string[] {
  const keys = LIBRARY.map((item) => item.id);
  const plain: string[] = [];
  // 19 plain single-key groups (keys 0..18).
  for (let i = 0; i < 19; i++) plain.push(`@${keys[i]}`);
  // 6 plain two-key groups.
  for (let i = 0; i < 6; i++) plain.push(`@${keys[19 + i]}; @${keys[(25 + i) % keys.length]}`);
  // 1 three-key group, 1 prefix group, 1 suppressed-author group.
  plain.push(`@${keys[30]}; @${keys[31]}; @${keys[32]}`);
  plain.push(`see @${keys[33]}`);
  plain.push(`-@${keys[34]}`);
  // That is 28 distinct plain groups. Two of them appear a second time later in the chapter.

  const located: string[] = [];
  for (let i = 0; i < 38; i++) {
    const page = 10 + i * 7 + shift * 1000;
    const key = keys[(i * 3) % keys.length];
    switch (i % 4) {
      case 0:
        located.push(`@${key}, p. ${page}`);
        break;
      case 1:
        located.push(`@${key}, pp. ${page}–${page + 9}`);
        break;
      case 2:
        located.push(`@${key}, p. ${page}; @${keys[(i * 3 + 1) % keys.length]}, ch. ${i + 1 + shift * 1000}`);
        break;
      default:
        located.push(`@${key}, p. ${page}, ${page + 4}`);
        break;
    }
  }

  // Interleave plain and located groups the way running text does, then repeat two plain groups.
  const chapter: string[] = [];
  let p = 0;
  let l = 0;
  while (p < plain.length || l < located.length) {
    if (l < located.length) chapter.push(located[l++]);
    if (p < plain.length) chapter.push(plain[p++]);
    if (l < located.length) chapter.push(located[l++]);
  }
  chapter.push(plain[0], plain[7]);
  return chapter;
}

export function documentGroups(chapters: number, shiftPages: boolean): Group[] {
  const groups: Group[] = [];
  for (let c = 0; c < chapters; c++) {
    for (const inner of chapterBrackets(shiftPages ? c : 0)) groups.push(groupFromBracket(inner));
  }
  return groups;
}
