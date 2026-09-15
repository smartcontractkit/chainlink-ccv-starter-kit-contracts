# Changelogs

One optional file per release tag, named after the tag: `v0.2.0.md` for tag `v0.2.0`.

When the tag is pushed, the release workflow prepends this file to the draft release notes,
above the auto-generated list of merged pull requests. Use it for what that list cannot say:
breaking changes, upgrade steps, and anything an operator must do before deploying.

Land it on `main` through a pull request before pushing the tag. The workflow reads the file
from the tagged commit, so a tag that predates it will not pick it up. A tag without a file
still gets a draft release with the auto-generated list alone.
