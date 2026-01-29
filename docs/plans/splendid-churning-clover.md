# Merge Conflict Resolution: annotations branch → main

## Conflict Summary

File: `web/milkdown/src/main.ts`

### Conflict 1: slashCommands array (lines 124-136)

**HEAD (main):** Has improved `/h1`, `/h2`, `/h3` commands using `headingLevel` property for proper node transformation
```typescript
{ label: '/h1', replacement: '', description: 'Heading 1', headingLevel: 1 },
{ label: '/h2', replacement: '', description: 'Heading 2', headingLevel: 2 },
{ label: '/h3', replacement: '', description: 'Heading 3', headingLevel: 3 },
```

**annotations:** Has original heading commands plus new annotation commands
```typescript
{ label: '/h1', replacement: '# ', description: 'Heading 1' },
{ label: '/h2', replacement: '## ', description: 'Heading 2' },
{ label: '/h3', replacement: '### ', description: 'Heading 3' },
{ label: '/task', replacement: '', description: 'Insert task annotation', isNodeInsertion: true },
{ label: '/comment', replacement: '', description: 'Insert comment annotation', isNodeInsertion: true },
{ label: '/reference', replacement: '', description: 'Insert reference annotation', isNodeInsertion: true },
```

### Conflict 2: executeSlashCommand function (lines 288-343)

**HEAD (main):** Has heading transformation logic using `cmd.headingLevel`
**annotations:** Has annotation insertion logic for `/task`, `/comment`, `/reference`

## Resolution Strategy

**Keep both:** Merge the improved heading commands from HEAD with the annotation commands from annotations.

### Resolved slashCommands array:
```typescript
{ label: '/h1', replacement: '', description: 'Heading 1', headingLevel: 1 },
{ label: '/h2', replacement: '', description: 'Heading 2', headingLevel: 2 },
{ label: '/h3', replacement: '', description: 'Heading 3', headingLevel: 3 },
{ label: '/task', replacement: '', description: 'Insert task annotation', isNodeInsertion: true },
{ label: '/comment', replacement: '', description: 'Insert comment annotation', isNodeInsertion: true },
{ label: '/reference', replacement: '', description: 'Insert reference annotation', isNodeInsertion: true },
```

### Resolved executeSlashCommand:
Keep BOTH the `headingLevel` handling block AND the annotation insertion block (in that order).

## Implementation Steps

1. Edit lines 124-136 to combine both command sets (keeping HEAD's `headingLevel` approach for headings, adding annotation commands)
2. Edit lines 288-343 to keep both code blocks:
   - First: the `headingLevel` handling from HEAD
   - Then: the annotation insertion handling from annotations
3. Run `pnpm build` to verify the merge compiles
4. Test in app to verify both heading commands and annotation commands work

## Files to Modify

- `web/milkdown/src/main.ts` - resolve the two conflict regions

## Verification

1. Build: `cd web && pnpm build`
2. Launch app and test:
   - Type `/h1`, `/h2`, `/h3` → should create proper headings
   - Type `/task`, `/comment`, `/reference` → should create annotation nodes
