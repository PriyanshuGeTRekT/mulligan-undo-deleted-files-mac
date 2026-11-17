# Changelog

## 1.0.0

First release.

- Menu-bar app that keeps an instant APFS copy of every file in the folders you protect (Desktop, Documents and Downloads by default)
- Recently deleted list with one-click restore, byte for byte, never overwriting
- Mass-deletion alarm: one alert with Restore all when many files vanish at once
- Version history for every file, search across live and deleted files, restore a folder as it was at any time
- `mulligan` command line: `status`, `deleted`, `find`, `history`, `restore`, `restore-tree`, `run`, `undo-run`, `checkpoint`, `forget`, `doctor`
- Retention: everything for 24 hours, hourly for a week, daily after that; deleted files kept 30 days; a space budget and automatic release when the disk is low
- Rename and move detection, iCloud placeholders skipped, vault excluded from Time Machine and Spotlight
