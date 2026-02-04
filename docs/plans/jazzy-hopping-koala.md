# Plan: Stage and Clean Git Changes

## Task
Stage intentional changes and discard cleanup deletions.

## Actions

### Stage (6 files):
1. `README.md` - Rewritten user documentation
2. `final final/Resources/getting-started.md` - Rewritten in-app help
3. `project.yml` - Version 0.2.8 → 0.2.13
4. `web/package.json` - Version 0.2.8 → 0.2.13
5. `final final.xcodeproj/project.pbxproj` - Version bump (auto-generated)
6. `scripts/build-and-distribute.sh` - Ad-hoc signing + ditto fix

### Discard (restore 3 deleted files):
1. `test-data/corrupted-backups/demo1-copy-3.ff/content.sqlite`
2. `test-data/corrupted-backups/demo2-copy.ff/content.sqlite`
3. `web/docs/plans/crystalline-inventing-globe.md`

## Commands
```bash
git add README.md "final final/Resources/getting-started.md" project.yml web/package.json "final final.xcodeproj/project.pbxproj" scripts/build-and-distribute.sh

git restore test-data/corrupted-backups/demo1-copy-3.ff/content.sqlite test-data/corrupted-backups/demo2-copy.ff/content.sqlite web/docs/plans/crystalline-inventing-globe.md
```
