#!/usr/bin/env bash
#
# Pull new upstream commits (IBM/mac-ibm-migration-tool) into this fork as ONE reviewable pull request.
#
# How it works
#   - .github/upstream-sync.base holds the upstream commit this fork was last synced to.
#   - Upstream's history has been rewritten before, so a plain `git merge` can't be trusted. Instead
#     this does a content-based 3-way merge:  base = last synced upstream commit,
#     ours = this fork's wku-customizations branch (with WKU customizations), theirs = upstream's current main.
#       * a WKU change upstream didn't touch ............ kept
#       * a file both sides changed in different places .. merged
#       * a WKU change upstream now has too ............... collapses into upstream's version (no duplicate)
#       * overlapping edits ............................... conflict, PR is opened as a draft with markers
#   - The result is committed (parents: fork main + upstream commit) to branch upstream-sync/latest,
#     with the marker advanced, and a PR is opened or updated. The PR body lists the new upstream
#     commits and the status of every WKU-customized file.
#   - Merging the PR is the approval. The workflow then tags wku-customizations and the WKU Signed
#     Release workflow builds, signs, notarizes and publishes it.
#
# Needs SYNC_TOKEN (passed as GH_TOKEN): fine-grained PAT for this repo with Contents, Pull requests,
# Issues and Workflows read/write. GITHUB_TOKEN can't push upstream's .github/workflows changes and
# PRs it opens don't trigger CI.
#
# Usage:  GH_TOKEN=... tools/ci-upstream-sync.sh
#         DRY_RUN=true tools/ci-upstream-sync.sh   (no push, no PR; writes the PR body to the work dir)
#         FORCE=true ...                           (overwrite upstream-sync/latest even if it has manual commits)

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-IBM/mac-ibm-migration-tool}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/${UPSTREAM_REPO}.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
FORK_REPO="${GITHUB_REPOSITORY:-bigdoodr/wkuxFer}"
BASE_BRANCH="${BASE_BRANCH:-wku-customizations}"
SYNC_BRANCH="upstream-sync/latest"
MARKER=".github/upstream-sync.base"
BOT_NAME="wkuxfer-upstream-sync"
BOT_EMAIL="noreply@users.noreply.github.com"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"

# The sync machinery itself isn't a "customization" worth reporting on.
SYNC_FILES=(
    ".github/upstream-sync.base"
    ".github/workflows/upstream-sync.yml"
    ".github/workflows/wku-ci.yml"
    ".github/workflows/wku-release.yml"
    "tools/ci-upstream-sync.sh"
    "tools/ci-build-release.sh"
    "docs/WKU-RELEASES.md"
)
# Upstream-owned identifiers WKU rewrites (bundle ID, display name, Bonjour service). New lines upstream
# adds that contain these get called out so they can be reviewed for rebranding.
REBRAND_PATTERN="com\.company\.|Mac@IBM|_migrator\._tcp"

die() { echo "::error::$*" >&2; exit 1; }

repoRoot="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "${repoRoot}"
workDir="${SYNC_WORK_DIR:-$( mktemp -d )}"
mkdir -p "${workDir}"

if [[ "${DRY_RUN}" != "true" ]]; then
    [[ -n "${GH_TOKEN:-}" ]] || die "SYNC_TOKEN secret is not set. See docs/WKU-RELEASES.md (One-time setup)."
fi

# ---------------------------------------------------------------------------------------------
# Fetch

git remote get-url upstream >/dev/null 2>&1 && git remote set-url upstream "${UPSTREAM_URL}" || git remote add upstream "${UPSTREAM_URL}"
git fetch -q --no-tags origin "+refs/heads/${BASE_BRANCH}:refs/remotes/origin/${BASE_BRANCH}"
git fetch -q --no-tags upstream "+refs/heads/${UPSTREAM_BRANCH}:refs/remotes/upstream/${UPSTREAM_BRANCH}"
git fetch -q upstream "+refs/tags/*:refs/upstream-tags/*" 2>/dev/null || true

forkRef="refs/remotes/origin/${BASE_BRANCH}"
upRef="refs/remotes/upstream/${UPSTREAM_BRANCH}"
forkSHA="$( git rev-parse "${forkRef}" )"
upSHA="$( git rev-parse "${upRef}" )"

baseSHA="$( git show "${forkRef}:${MARKER}" 2>/dev/null | tr -d '[:space:]' || true )"
[[ -n "${baseSHA}" ]] || die "${MARKER} is missing on ${BASE_BRANCH}; it must contain the upstream commit this fork was last synced to."
if ! git cat-file -e "${baseSHA}^{commit}" 2>/dev/null; then
    git fetch -q --no-tags upstream "${baseSHA}" 2>/dev/null || true
fi
git cat-file -e "${baseSHA}^{commit}" 2>/dev/null \
    || die "Last-synced upstream commit ${baseSHA} can't be fetched (upstream history rewritten?). Set ${MARKER} to a commit whose tree matches what this fork last absorbed."

if [[ "${upSHA}" == "${baseSHA}" ]]; then
    echo "Already in sync with upstream (${upSHA:0:7}); nothing to do."
    exit 0
fi
if git merge-base --is-ancestor "${upSHA}" "${forkRef}"; then
    echo "Fork ${BASE_BRANCH} already contains upstream ${upSHA:0:7}; nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------------------------
# Merge by content against the recorded base

set +e
mergeOut="$( git merge-tree --write-tree --name-only --merge-base="${baseSHA}" "${forkRef}" "${upSHA}" 2>"${workDir}/merge.err" )"
mergeRC=$?
set -e
(( mergeRC == 0 || mergeRC == 1 )) || { cat "${workDir}/merge.err" >&2; die "git merge-tree failed (needs git 2.40+)."; }
mergedTree="$( head -1 <<<"${mergeOut}" )"
conflicts="$( awk 'NR==1{next} /^$/{exit} {print}' <<<"${mergeOut}" )"
hasConflicts=false; [[ -n "${conflicts}" ]] && hasConflicts=true

# Advance the marker inside the merged tree (plumbing only; no checkout needed).
tmpIndex="$( mktemp -u )"
markerBlob="$( printf '%s\n' "${upSHA}" | git hash-object -w --stdin )"
newTree="$( GIT_INDEX_FILE="${tmpIndex}" bash -c '
    git read-tree "$1" && git update-index --add --cacheinfo "100644,$2,$3" && git write-tree
' _ "${mergedTree}" "${markerBlob}" "${MARKER}" )"
rm -f "${tmpIndex}"

if git merge-base --is-ancestor "${baseSHA}" "${upSHA}"; then
    linear=true
    newCommits="$( git rev-list --count "${baseSHA}..${upSHA}" )"
else
    linear=false
    newCommits="?"
fi

# ---------------------------------------------------------------------------------------------
# Report

mapfile -t customized < <( git diff --no-renames --name-only "${baseSHA}" "${forkRef}" \
    | grep -vxF -f <( printf '%s\n' "${SYNC_FILES[@]}" ) || true )

blobOf() { git rev-parse -q --verify "${1}:${2}" 2>/dev/null || echo "-"; }

{
    if ${hasConflicts}; then
        echo "> [!WARNING]"
        echo "> **$(echo "${conflicts}" | wc -l | tr -d ' ') file(s) conflict** between WKU customizations and upstream's changes. The conflict markers are committed on this branch so the diff shows exactly where. Resolve them on \`${SYNC_BRANCH}\` and push; CI must pass before merging."
        echo
    fi
    echo "Syncs this fork with [\`${UPSTREAM_REPO}@${upSHA:0:7}\`](https://github.com/${UPSTREAM_REPO}/commit/${upSHA}) (previous sync point: [\`${baseSHA:0:7}\`](https://github.com/${UPSTREAM_REPO}/commit/${baseSHA}))."
    echo
    echo "Merging this PR advances the sync point and cuts a new release from \`${BASE_BRANCH}\`."
    echo
    echo "### Upstream changes ($(git diff --shortstat "${baseSHA}" "${upSHA}" | sed 's/^ *//'))"
    echo
    if ${linear}; then
        git log --no-merges --format="- [\`%h\`](https://github.com/${UPSTREAM_REPO}/commit/%H) %s" "${baseSHA}..${upSHA}" | head -60
        (( newCommits > 60 )) && echo "- … and more (${newCommits} commits in total)"
    else
        echo "_Upstream history was rewritten since the last sync, so changes were compared by content rather than by commit._"
    fi
    echo
    relTags=""
    while read -r ref; do
        c="$( git rev-parse "${ref}^{commit}" 2>/dev/null )" || continue
        if ! git merge-base --is-ancestor "${c}" "${baseSHA}" && git merge-base --is-ancestor "${c}" "${upSHA}"; then
            relTags+="\`${ref#refs/upstream-tags/}\` "
        fi
    done < <( git for-each-ref --format='%(refname)' refs/upstream-tags )
    [[ -n "${relTags}" ]] && { echo "Upstream releases in this range: ${relTags}"; echo; }

    echo "### WKU customizations"
    echo
    if (( ${#customized[@]} == 0 )); then
        echo "_The fork currently has no changes beyond upstream._"
    else
        echo "| File | Status | Still differs from upstream |"
        echo "|---|---|---|"
        for f in "${customized[@]}"; do
            b="$( blobOf "${baseSHA}" "${f}" )"; up="$( blobOf "${upSHA}" "${f}" )"; mg="$( blobOf "${mergedTree}" "${f}" )"
            if grep -qxF "${f}" <<<"${conflicts}"; then
                status="⚠️ **conflict**"
            elif [[ "${mg}" == "${up}" ]]; then
                status="✅ absorbed (now identical to upstream)"
            elif [[ "${up}" == "${b}" ]]; then
                status="kept (upstream didn't touch this file)"
            else
                status="kept, merged with upstream's changes to the same file"
            fi
            delta="$( git diff --numstat "${upSHA}" "${newTree}" -- "${f}" | awk '{ if ($1 == "-") print "binary"; else print "+" $1 " / −" $2 }' )"
            echo "| \`${f}\` | ${status} | ${delta:-none} |"
        done
    fi
    echo
    rebrand="$( git diff -U0 "${baseSHA}" "${upSHA}" | awk -v pat="${REBRAND_PATTERN}" '
        /^\+\+\+ /{ f = substr($2, 3) } /^\+[^+]/ && $0 ~ pat { print "- `" f "`: `" substr($0, 2) "`" }' | head -20 )"
    if [[ -n "${rebrand}" ]]; then
        echo "### Review for WKU rebranding"
        echo
        echo "Lines upstream added that contain upstream's identifier (\`${REBRAND_PATTERN//\\/}\`):"
        echo
        echo "${rebrand}"
        echo
    fi
    echo "<details><summary>Files changed upstream</summary>"
    echo
    echo '```'
    git diff --stat=100 "${baseSHA}" "${upSHA}" | head -80
    echo '```'
    echo "</details>"
    if ${hasConflicts}; then
        echo
        echo "### Resolving conflicts"
        echo
        echo '```sh'
        echo "git fetch origin && git checkout ${SYNC_BRANCH}"
        echo "# edit the files below, remove the <<<<<<< / ======= / >>>>>>> markers"
        echo "git add -A && git commit -m \"Resolve upstream sync conflicts\" && git push"
        echo '```'
        echo
        echo "$( echo "${conflicts}" | sed 's/^/- `/; s/$/`/' )"
        echo
        echo "While this branch has commits that aren't from the sync bot, the daily job won't overwrite it."
    fi
} > "${workDir}/pr-body.md"

title="Sync with upstream ${UPSTREAM_REPO} (${newCommits} new commits, up to ${upSHA:0:7})"
${hasConflicts} && title+=" — CONFLICTS"

commitMsg="Sync with upstream ${UPSTREAM_REPO}@${upSHA:0:7}

Previous sync point: ${baseSHA}
New sync point:      ${upSHA}"
syncCommit="$( GIT_AUTHOR_NAME="${BOT_NAME}" GIT_AUTHOR_EMAIL="${BOT_EMAIL}" GIT_COMMITTER_NAME="${BOT_NAME}" GIT_COMMITTER_EMAIL="${BOT_EMAIL}" \
    git commit-tree "${newTree}" -p "${forkSHA}" -p "${upSHA}" -m "${commitMsg}" )"

echo "Upstream ${baseSHA:0:7} -> ${upSHA:0:7}: ${newCommits} commits; conflicts: ${hasConflicts}; sync commit ${syncCommit:0:7}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    { echo "### Upstream sync"; echo; echo "${title}"; echo; cat "${workDir}/pr-body.md"; } >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "DRY RUN: would push ${syncCommit} to ${SYNC_BRANCH} and open/update a PR titled: ${title}"
    echo "PR body: ${workDir}/pr-body.md"
    git update-ref "refs/heads/dry-run-${SYNC_BRANCH//\//-}" "${syncCommit}"
    exit 0
fi

# ---------------------------------------------------------------------------------------------
# Push the branch (unless someone has been working on it) and open/update the PR

git fetch -q --no-tags origin "+refs/heads/${SYNC_BRANCH}:refs/remotes/origin/${SYNC_BRANCH}" 2>/dev/null || true
remoteSync="$( git rev-parse -q --verify "refs/remotes/origin/${SYNC_BRANCH}" || true )"
if [[ -n "${remoteSync}" && "${FORCE}" != "true" ]]; then
    lastAuthor="$( git log -1 --format=%an "${remoteSync}" )"
    if [[ "${lastAuthor}" != "${BOT_NAME}" ]]; then
        echo "::warning::${SYNC_BRANCH} has manual commits (last by ${lastAuthor}); leaving it alone. Merge or close that PR, or run with force."
        exit 0
    fi
fi

if [[ -n "${remoteSync}" && "$( git rev-parse "${remoteSync}^{tree}" )" == "${newTree}" ]]; then
    echo "${SYNC_BRANCH} is already up to date."
else
    git push -q --force origin "${syncCommit}:refs/heads/${SYNC_BRANCH}"
fi

gh label create "upstream-sync" -R "${FORK_REPO}" --color 1D76DB --description "Sync with upstream IBM Data Shift" >/dev/null 2>&1 || true
gh label create "needs-resolution" -R "${FORK_REPO}" --color B60205 --description "Merge conflicts to resolve" >/dev/null 2>&1 || true

existing="$( gh pr list -R "${FORK_REPO}" --head "${SYNC_BRANCH}" --base "${BASE_BRANCH}" --state open --json number --jq '.[0].number // empty' )"
if [[ -z "${existing}" ]]; then
    args=(--base "${BASE_BRANCH}" --head "${SYNC_BRANCH}" --title "${title}" --body-file "${workDir}/pr-body.md" --label upstream-sync)
    ${hasConflicts} && args+=(--draft --label needs-resolution)
    gh pr create -R "${FORK_REPO}" "${args[@]}"
else
    gh pr edit "${existing}" -R "${FORK_REPO}" --title "${title}" --body-file "${workDir}/pr-body.md"
    if ${hasConflicts}; then
        gh pr edit "${existing}" -R "${FORK_REPO}" --add-label needs-resolution >/dev/null || true
        gh pr ready "${existing}" -R "${FORK_REPO}" --undo >/dev/null 2>&1 || true
    else
        gh pr edit "${existing}" -R "${FORK_REPO}" --remove-label needs-resolution >/dev/null 2>&1 || true
        gh pr ready "${existing}" -R "${FORK_REPO}" >/dev/null 2>&1 || true
    fi
    echo "Updated PR #${existing}"
fi
