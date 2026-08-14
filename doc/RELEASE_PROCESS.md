# Release process

`VERSION` is the canonical MushroomProcess version. The README, changelog, release notes, and Git tag must agree with it.

## Prepare and verify

From a clean `production` branch:

```bash
make prepare-release VERSION=1.2.1 RELEASE_DATE=2026-08-13
# Complete doc/CHANGELOG.md and releases/v1.2.1/RELEASE_NOTES.md.
make release-check
git diff --check
```

The preparation command changes files only. It does not commit, tag, push, deploy, or publish a GitHub release. After review, commit the release files, tag them as `vX.Y.Z`, and push the commit and tag.

## Coordinated releases

For a concurrent Rooted software baseline, record the exact four tags in the coordination manifest. A coordinated release means the versions were validated together; it does not require the projects to share version numbers.
