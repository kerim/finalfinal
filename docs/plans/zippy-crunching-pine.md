# Plan: Add Biome Linting to Web Editors

## Goal
Set up Biome for linting and formatting the TypeScript/CSS code in `web/milkdown/` and `web/codemirror/`.

## Steps

### 1. Install Biome
Add Biome as a workspace dev dependency:
```bash
cd web && pnpm add -D @biomejs/biome -w
```

### 2. Create Configuration
Create `web/biome.json` with settings appropriate for this project:
- Enable TypeScript linting
- Enable CSS linting (for the style files)
- Configure formatter to match existing code style (tabs vs spaces, etc.)
- Ignore `node_modules/` and build output

### 3. Add Scripts
Update `web/package.json` to add:
```json
"scripts": {
  "lint": "biome check .",
  "lint:fix": "biome check --write .",
  "format": "biome format --write ."
}
```

### 4. Initial Lint Run
Run `pnpm lint` to identify any existing issues, then `pnpm lint:fix` to auto-fix what can be fixed.

### 5. Review and Adjust
Review any remaining warnings/errors and either:
- Fix them manually
- Adjust Biome rules if they're too strict for this codebase

## Files to Modify
- `web/package.json` - add scripts and dependency
- `web/biome.json` - new file (Biome configuration)

## Verification
1. Run `pnpm lint` - should complete without errors
2. Run `pnpm format` on a file, verify formatting looks correct
3. Intentionally introduce a lint error, verify it's caught
