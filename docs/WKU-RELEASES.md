# Upstream sync and signed releases

This fork ([bigdoodr/wkuxFer](https://github.com/bigdoodr/wkuxFer)) tracks
[IBM/mac-ibm-migration-tool](https://github.com/IBM/mac-ibm-migration-tool). WKU's changes live on the
`wku-customizations` branch (the default branch). New upstream work arrives as a pull request; merging that
PR produces a signed, notarized release.

## What happens

1. **Daily**, [Upstream Sync](../.github/workflows/upstream-sync.yml) compares upstream's `main` with the
   commit recorded in `.github/upstream-sync.base`. If upstream has moved, it merges upstream's changes with
   the WKU customizations and opens (or updates) one PR from `upstream-sync/latest` into `wku-customizations`.
2. **The PR shows what to review:** the new upstream commits and tags (upstream tags betas and release
   candidates too, so check the "Upstream releases in this range" line), every file WKU customizes and what
   became of it, and new upstream lines that contain identifiers WKU rewrites (bundle ID, display name,
   Bonjour service).

   | Status in the PR | Meaning |
   |---|---|
   | kept | upstream didn't touch the file; the WKU change is untouched |
   | kept, merged | both changed the file, in different places; both changes are in |
   | absorbed | upstream now has the same change; nothing left to carry |
   | **conflict** | both edited the same lines. The PR is a **draft** labeled `needs-resolution`, with conflict markers committed so the diff shows where |
3. **WKU CI builds the PR** ([wku-ci.yml](../.github/workflows/wku-ci.yml), unsigned). It fails while
   conflict markers remain or if the app doesn't build.
4. **Merge the PR.** That advances `.github/upstream-sync.base` and tags `wku-customizations` as
   `vYYYY.MM.DD.HHMM` (Central time). The tag starts
   [WKU Signed Release](../.github/workflows/wku-release.yml), which builds the app, signs it with the
   Developer ID Application certificate, has Apple notarize it, builds the `.pkg` (Developer ID Installer)
   and `.dmg` from the stapled app, and publishes the release with `SHA256SUMS`.

Run **Actions → WKU Signed Release → Run workflow** with an existing tag to rebuild any release.

If upstream publishes again before you merge, the same PR is updated in place. If you push your own commits
to `upstream-sync/latest` (for example to resolve a conflict), the daily job stops touching the branch so
your work isn't overwritten; merge or close the PR to resume. Run the workflow manually with **force** to
overwrite it anyway.

## Why it isn't a plain `git merge`

The job does a three-way merge by **content**: base = the upstream commit in `.github/upstream-sync.base`,
ours = `wku-customizations`, theirs = upstream's `main`. A change WKU made that upstream later makes too
collapses into upstream's version, and rewritten upstream history can't break it.

## One-time setup

1. **Make `wku-customizations` the default branch** (Settings → Branches). Scheduled workflows only run from
   the default branch. `main` can stay as it is; nothing here uses it.
2. **Enable Actions** on the fork (Actions tab). GitHub turns them off on forks by default and pauses
   scheduled workflows after 60 days without repository activity.
3. **Add the `SYNC_TOKEN` secret** (Settings → Secrets and variables → Actions): a fine-grained personal
   access token limited to this repository with **Contents**, **Pull requests**, **Issues** and
   **Workflows** set to *Read and write*. The built-in `GITHUB_TOKEN` can't push upstream's
   `.github/workflows` changes, PRs it opens don't start CI, and tags it pushes don't start the release
   workflow.
4. **Create the environment.** Settings → Environments → New environment → `release-signing`.
   - Add yourself under *Required reviewers* so every signing run waits for your approval.
   - Under *Deployment branches and tags*, select *Selected branches and tags* and allow `wku-customizations`
     as a branch and `v*` as a tag (the release runs on the tag).
5. **Add these as secrets of the `release-signing` environment** (the same values the ASBMUtil fork uses;
   environment secrets are per repository, so they have to be added here too):

   | Secret | Value |
   |---|---|
   | `APPLE_APP_CERT_P12_BASE64` | base64 of the Developer ID Application certificate `.p12` |
   | `APPLE_APP_CERT_P12_PASSWORD` | its export password |
   | `APPLE_INSTALLER_CERT_P12_BASE64` | base64 of the Developer ID Installer certificate `.p12` |
   | `APPLE_INSTALLER_CERT_P12_PASSWORD` | its export password |
   | `NOTARY_APPLE_ID` | Apple ID of the developer account |
   | `NOTARY_APP_SPECIFIC_PASSWORD` | an app-specific password from account.apple.com |
   | `NOTARY_TEAM_ID` | the 10-character Team ID |

   Export each certificate from Keychain Access with its private key (right-click → Export → `.p12`), then
   `base64 -i cert.p12 | pbcopy`.
6. **Try it:** Actions → Upstream Sync → Run workflow, then merge the PR it opens (see below), or run
   WKU Signed Release by hand against an existing tag.

## The first sync will conflict

`.github/upstream-sync.base` starts at `6c64575` (the upstream commit this fork was branched from, v1.4.1).
Upstream `main` has since moved to 2.0.0, so the first PR is a **draft** with conflicts in
`migrator.xcodeproj/project.pbxproj` (version numbers, deployment target, entitlements setting and the
signing/branding lines next to them) and `migrator/AppContext.swift` (the WKU default values). Resolve them
on `upstream-sync/latest`, push, and merge; later syncs start from the new sync point.

Version bumps upstream sit next to the branding lines WKU changed in `project.pbxproj`, so expect small
conflicts there again on later syncs unless those overrides move out of the Xcode project.

## Things to know

- CI signs with `codesign` after an unsigned `xcodebuild`, so the project's own signing settings
  (Automatic / Apple Development) are not used or changed by releases.
- The Team ID is whatever the certificates belong to. If it ever changes, anything on the Macs written
  against the old Team ID (Mosyle PPPC, login-item or background-task rules) must be updated.
- Upstream's `main.yml` and `codeql.yml` only run for their own branches (main/dev) and are left as they
  are so syncs don't conflict with them.
- Not tested on a real runner when written: the first release may need adjustments. Run
  WKU Signed Release with a tag and watch the log before relying on it.

## Local dry run

```sh
DRY_RUN=true tools/ci-upstream-sync.sh     # pushes nothing; prints where the PR body was written
```

Needs git 2.40+ (`git merge-tree --write-tree`).
