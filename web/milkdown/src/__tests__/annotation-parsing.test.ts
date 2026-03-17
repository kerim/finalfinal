import { describe, expect, it } from 'vitest';
import { annotationRegex, createAnnotationMarkdown, taskCheckboxRegex } from '../annotation-plugin';

describe('annotationRegex', () => {
  it('matches task annotation with unchecked checkbox', () => {
    const input = '<!-- ::task:: [ ] Review introduction -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('task');
    expect(match![2]).toBe('[ ] Review introduction');
  });

  it('matches task annotation with checked checkbox', () => {
    const input = '<!-- ::task:: [x] Done item -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('task');
    expect(match![2]).toBe('[x] Done item');
  });

  it('matches comment annotation', () => {
    const input = '<!-- ::comment:: Needs expanded discussion -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('comment');
    expect(match![2]).toBe('Needs expanded discussion');
  });

  it('matches reference annotation', () => {
    const input = '<!-- ::reference:: See also Smith 2023 -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('reference');
    expect(match![2]).toBe('See also Smith 2023');
  });

  it('matches annotation with empty content', () => {
    const input = '<!-- ::comment:: -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('comment');
    expect(match![2]).toBe('');
  });

  it('does not match regular HTML comments', () => {
    const input = '<!-- Just a regular comment -->';
    const match = input.match(annotationRegex);
    expect(match).toBeNull();
  });

  it('does not match malformed annotations', () => {
    const input = '<!-- ::notclosed text -->';
    const match = input.match(annotationRegex);
    expect(match).toBeNull();
  });

  it('handles extra whitespace', () => {
    const input = '<!--  ::task::  [ ] Spacey  -->';
    const match = input.match(annotationRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('task');
  });
});

describe('taskCheckboxRegex', () => {
  it('matches unchecked checkbox [ ]', () => {
    const match = '[ ] Review this'.match(taskCheckboxRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe(' ');
    expect(match![2]).toBe('Review this');
  });

  it('matches checked checkbox [x]', () => {
    const match = '[x] Done'.match(taskCheckboxRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('x');
    expect(match![2]).toBe('Done');
  });

  it('matches uppercase [X]', () => {
    const match = '[X] Also done'.match(taskCheckboxRegex);
    expect(match).not.toBeNull();
    expect(match![1]).toBe('X');
  });

  it('does not match non-checkbox text', () => {
    const match = 'Just some text'.match(taskCheckboxRegex);
    expect(match).toBeNull();
  });
});

describe('createAnnotationMarkdown', () => {
  it('creates task markdown with empty checkbox', () => {
    const result = createAnnotationMarkdown('task', 'Do something');
    expect(result).toBe('<!-- ::task:: [ ] Do something -->');
  });

  it('creates comment markdown', () => {
    const result = createAnnotationMarkdown('comment', 'A note');
    expect(result).toBe('<!-- ::comment:: A note -->');
  });

  it('creates reference markdown', () => {
    const result = createAnnotationMarkdown('reference', 'See paper');
    expect(result).toBe('<!-- ::reference:: See paper -->');
  });

  it('creates task with empty text', () => {
    const result = createAnnotationMarkdown('task');
    expect(result).toBe('<!-- ::task:: [ ]  -->');
  });
});
