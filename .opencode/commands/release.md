---
description: Release a new version of the gem
agent: build
---

Release a new version of the capistrano-nomad gem.

## Current State

Current version: !`grep -m1 'spec.version' capistrano-nomad.gemspec | sed 's/.*"\(.*\)"/\1/'`

Changes pending release:
!`sed -n '/## \[Unreleased\]/,/## \[/p' CHANGELOG.md | head -20`

## Steps to perform:

1. **Ask what version to release** (unless specified via arguments: $ARGUMENTS)

2. **Update the version** in `capistrano-nomad.gemspec` (line 5: `spec.version = "X.Y.Z"`)

3. **Update CHANGELOG.md**:
   - Rename `[Unreleased]` section to the new version number (e.g., `## [0.15.0]`)
   - Add a new empty `## [Unreleased]` section at the top

4. **Commit the version bump**:
   ```shell
   git add capistrano-nomad.gemspec CHANGELOG.md
   git commit -m "X.Y.Z"
   ```

5. **Run the release command**:
   ```shell
   bundle exec rake release
   ```

   This will:
   - Create a git tag for the version
   - Push git commits and the created tag
   - Push the `.gem` file to rubygems.org
