# Table Roundtrip Fixture

This file is the golden fixture for table serialization tests. It covers all
inline-mark types, alignment variants, edge cases, and the accumulation guard.

## Basic alignment table

| Left             | Center           | Right            | Default      |
| :--------------- | :--------------: | ---------------: | ------------ |
| **bold cell**    | *italic cell*    | `code cell`      |              |
| [link](https://example.com) | ==highlight== | pipe\|here | normal |

## Mark preservation table

| Mark     | Example             | Notes           |
| -------- | ------------------- | --------------- |
| Bold     | **strong text**     | should survive  |
| Italic   | *emphasized text*   | should survive  |
| Code     | `inline code`       | pipes not escaped inside |
| Link     | [example](https://example.com) | URL intact |
| Highlight | ==marked text==   | custom mark     |

## Edge cases

| Edge case        | Value              |
| ---------------- | ------------------ |
| Empty cell       |                    |
| Pipe escaped     | pipe\|character    |
| Code with pipe   | `a\|b`             |
| Multi-word bold  | **two words**      |
