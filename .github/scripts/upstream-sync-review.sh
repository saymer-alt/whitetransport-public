#!/usr/bin/env bash
# Upstream sync review v2: branch + release tracking for GitHub forks.
#
# Review-only automation. It NEVER:
#   - merges anything into the fork default branch (proposals go to sync/* branches + Draft PRs),
#   - force-pushes, resets, or rewrites history,
#   - executes upstream code (git fetch/rev-list/merge only),
#   - creates releases, tags, or runs upstream installers.
# The fork owner decides whether to accept any proposal.
#
# Required env: GITHUB_REPOSITORY, UPSTREAM_REPO, BRANCH, GH_TOKEN (Actions).
# SYNC_TEST_DIR / SYNC_UPSTREAM_URL are set ONLY by the local synthetic test
# harness; the workflow never sets them.

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?UPSTREAM_REPO is required}"
BRANCH="${BRANCH:?BRANCH is required}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
TEST_DIR="${SYNC_TEST_DIR:-}"
UPSTREAM_URL="${SYNC_UPSTREAM_URL:-https://github.com/$UPSTREAM_REPO.git}"

# Case format check only (defense in depth; the workflow repo-guard pins the value).
case "$UPSTREAM_REPO" in
  */*) : ;;
  *) echo "::error::UPSTREAM_REPO must be owner/repo, got '$UPSTREAM_REPO'"; exit 1 ;;
esac

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
log() { printf '%s\n' "$*" >> "$SUMMARY"; }
fail() { echo "::error::$*"; log "ERROR: $*"; exit 1; }

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git remote add upstream "$UPSTREAM_URL" 2>/dev/null || git remote set-url upstream "$UPSTREAM_URL"
git fetch --quiet --no-tags upstream "refs/heads/$BRANCH:refs/remotes/upstream/$BRANCH"
upstream_ref="refs/remotes/upstream/$BRANCH"
upstream_sha="$(git rev-parse "$upstream_ref")"
fork_sha="$(git rev-parse "origin/$BRANCH")"

log "## Upstream synchronization"
log "Upstream: $UPSTREAM_REPO ($BRANCH)"
log "Fork: $GITHUB_REPOSITORY ($BRANCH)"
log "Upstream SHA: $upstream_sha"
log "Fork SHA: $fork_sha"

# ---------------------------------------------------------------------------
# GitHub API seams (overridden by the local test harness)
# ---------------------------------------------------------------------------

fetch_latest_release() {
  if [[ -n "$TEST_DIR" ]]; then
    cat "$TEST_DIR/release.json" 2>/dev/null || true
  else
    # /releases/latest excludes drafts and prereleases by API contract;
    # 404 (no releases yet) comes back empty through the || true below.
    gh api "repos/$UPSTREAM_REPO/releases/latest" 2>/dev/null || true
  fi
}

fetch_releases_page() {
  if [[ -n "$TEST_DIR" ]]; then
    cat "$TEST_DIR/releases.json" 2>/dev/null || echo "[]"
  else
    gh api "repos/$UPSTREAM_REPO/releases?per_page=10" 2>/dev/null || echo "[]"
  fi
}

open_prs_json() {
  if [[ -n "$TEST_DIR" ]]; then
    cat "$TEST_DIR/open_prs.json" 2>/dev/null || echo "[]"
  else
    gh pr list --repo "$GITHUB_REPOSITORY" --state open --json number,headRefName,title,url
  fi
}

closed_prs_json() {
  if [[ -n "$TEST_DIR" ]]; then
    cat "$TEST_DIR/closed_prs.json" 2>/dev/null || echo "[]"
  else
    gh pr list --repo "$GITHUB_REPOSITORY" --state closed --json number,headRefName
  fi
}

create_draft_pr() { # $1 head, $2 title, $3 body -> prints PR url
  if [[ -n "$TEST_DIR" ]]; then
    if [[ -f "$TEST_DIR/fail_create" ]]; then
      echo "::error::simulated PR creation permission failure" >&2
      return 1
    fi
    printf 'PR %s | %s\n' "$1" "$2" >> "$TEST_DIR/prs.log"
    printf '%s' "$3" > "$TEST_DIR/last_pr_body.md"
    echo "https://example.invalid/pr/$1"
  else
    gh pr create --repo "$GITHUB_REPOSITORY" --draft --base "$BRANCH" --head "$1" \
      --title "$2" --body "$3"
  fi
}

pr_comment() { # $1 pr number-or-url, $2 body
  if [[ -n "$TEST_DIR" ]]; then
    printf 'COMMENT on %s: %s\n' "$1" "$2" >> "$TEST_DIR/prs.log"
  else
    gh pr comment "$1" --repo "$GITHUB_REPOSITORY" --body "$2" >/dev/null
  fi
}

# Comment only once per marker (marker = sync-state + upstream sha) to avoid spam.
pr_comment_once() { # $1 pr number, $2 marker, $3 body
  local marker_comment
  if [[ -n "$TEST_DIR" ]]; then
    if [[ -f "$TEST_DIR/prs.log" ]] && grep -qF "MARKER:$2" "$TEST_DIR/prs.log"; then
      return 0
    fi
    printf 'MARKER:%s\n' "$2" >> "$TEST_DIR/prs.log"
  else
    marker_comment="$(gh pr view "$1" --repo "$GITHUB_REPOSITORY" --json comments \
      --arg m "MARKER:$2" \
      --jq '[.comments[].body] | map(select(startswith($m))) | length' 2>/dev/null || echo 1)"
    [[ "$marker_comment" != "0" ]] && return 0
  fi
  pr_comment "$1" "MARKER:$2
$3"
}

# ---------------------------------------------------------------------------
# Part 1: branch tracking (upstream default branch)
# ---------------------------------------------------------------------------

behind="$(git rev-list --count "HEAD..$upstream_ref")"
ahead="$(git rev-list --count "$upstream_ref..HEAD")"
log "Behind by: $behind; fork-only commits: $ahead"

if (( behind > 0 )); then
  branch_pr="$(open_prs_json | python3 -c '
import json,sys
prs=json.load(sys.stdin)
for p in prs:
    h=p["headRefName"]
    if h.startswith("sync/upstream-") and not h.startswith("sync/upstream-release-"):
        print(p["number"], h, p["url"], sep=" "); break
' 2>/dev/null || true)"
  if [[ -n "$branch_pr" ]]; then
    read -r pr_num pr_head pr_url <<< "$branch_pr"
    if git ls-remote --exit-code --quiet origin "refs/heads/$pr_head"; then
      git fetch --quiet origin "refs/heads/$pr_head:refs/remotes/origin/$pr_head"
      if git merge-base --is-ancestor "$upstream_sha" "refs/remotes/origin/$pr_head"; then
        log "Existing branch-sync PR #$pr_num is already current with upstream $pr_url. No action."
      else
        # Scenario 3: upstream advanced past an open proposal. Prefer a clean,
        # non-force update of the proposal branch; never rewrite it.
        git switch --quiet --detach "refs/remotes/origin/$pr_head"
        if git merge --no-ff --no-edit "$upstream_sha" >/dev/null 2>&1; then
          git push --quiet origin "HEAD:refs/heads/$pr_head"
          log "Updated proposal branch $pr_head by merge (no force-push); PR #$pr_num now contains upstream $upstream_sha."
          pr_comment_once "$pr_num" "sync-update-$upstream_sha" \
            "Upstream advanced; proposal branch updated by a normal merge commit to upstream \`$upstream_sha\`. No force-push used."
        else
          git merge --abort >/dev/null 2>&1 || true
          log "WARN: upstream cannot be merged cleanly into proposal branch $pr_head; PR #$pr_num is outdated and needs manual attention."
          pr_comment_once "$pr_num" "sync-conflict-$upstream_sha" \
            "Upstream advanced to \`$upstream_sha\` but does not merge cleanly into this proposal branch. Left untouched (no force-push); a maintainer must rework the proposal manually."
        fi
        git switch --quiet --detach "origin/$BRANCH"
      fi
    else
      log "WARN: PR #$pr_num references missing branch $pr_head; skipping (manual cleanup required)."
    fi
  else
    sync_branch="sync/upstream-${upstream_sha:0:12}"
    # If an open release proposal already contains this upstream commit, a
    # separate branch proposal would duplicate its content.
    rel_head="$(open_prs_json | python3 -c '
import json,sys
for p in json.load(sys.stdin):
    if p["headRefName"].startswith("sync/upstream-release-"):
        print(p["headRefName"]); break
' 2>/dev/null || true)"
    if [[ -n "$rel_head" ]] && git ls-remote --quiet --exit-code origin "refs/heads/$rel_head" >/dev/null 2>&1 \
       && git fetch --quiet origin "refs/heads/$rel_head:refs/remotes/origin/$rel_head" 2>/dev/null \
       && git merge-base --is-ancestor "$upstream_sha" "refs/remotes/origin/$rel_head"; then
      log "Branch tracking: upstream $upstream_sha is already covered by open release proposal branch $rel_head; no separate proposal."
    elif git ls-remote --quiet --exit-code origin "refs/heads/$sync_branch" >/dev/null 2>&1; then
      log "WARN: branch $sync_branch already exists without an open PR; not overwriting. Manual check required."
    else
      git switch --quiet -c "$sync_branch" "origin/$BRANCH"
      if git merge --no-ff --no-edit "$upstream_ref" >/dev/null 2>&1; then
        git push --quiet origin "HEAD:refs/heads/$sync_branch"
        body="$(printf '%s\n' \
          '## Review-only upstream update (automated Draft PR)' \
          '' \
          "- Upstream: https://github.com/$UPSTREAM_REPO ($BRANCH)" \
          "- Upstream SHA: $upstream_sha" \
          "- Fork base SHA: $fork_sha" \
          "- Missing upstream commits: $behind; fork-only commits: $ahead" \
          '' \
          'Review workflows, scripts, licensing, third-party dependencies, transport protocols, secrets, and device compatibility BEFORE merge.' \
          'There is NO automatic merge, tag, release, or router/VPS deployment.' \
          'Passing a Git merge does NOT prove runtime/ARM64/MIPSel compatibility.' \
        )"
        if ! pr_url="$(create_draft_pr "$sync_branch" \
          "chore(upstream): review $UPSTREAM_REPO @ ${upstream_sha:0:12}" "$body")"; then
          fail "Sync branch $sync_branch pushed, but Draft PR creation was blocked (check Actions PR-creation permission)."
        fi
        log "Draft PR opened for branch update review: $pr_url; fork default branch unchanged."
      else
        git merge --abort >/dev/null 2>&1 || true
        fail "Scenario 4: upstream diverged and conflicts with fork history. No reset, no -X theirs, no force-push. Manual merge required."
      fi
      git switch --quiet --detach "origin/$BRANCH" 2>/dev/null || true
    fi
  fi
else
  log "Branch tracking: no upstream-only commits to propose."
fi

# ---------------------------------------------------------------------------
# Part 2: release tracking (published stable releases + tags)
# ---------------------------------------------------------------------------

rel_json="$(fetch_latest_release)"
if [[ -z "$rel_json" ]]; then
  log "Release tracking: no published stable release found upstream; idle."
  exit 0
fi

rel_tag="$(printf '%s' "$rel_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
rel_url="$(printf '%s' "$rel_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("html_url",""))')"
rel_pub="$(printf '%s' "$rel_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("published_at",""))')"
rel_notes="$(printf '%s' "$rel_json" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("body") or "")[:2500])')"

# Resolve the tag to its exact commit (fetch just that tag).
if ! tag_commit="$(git rev-parse --verify --quiet "refs/tags/$rel_tag^{commit}")"; then
  if ! git fetch --quiet upstream "refs/tags/$rel_tag:refs/tags/$rel_tag" 2>/dev/null; then
    log "WARN: release $rel_tag has no reachable Git tag; cannot verify SHA. Skipping release proposal (manual check)."
    exit 0
  fi
  tag_commit="$(git rev-parse --verify "refs/tags/$rel_tag^{commit}")"
fi

if git merge-base --is-ancestor "$tag_commit" "origin/$BRANCH"; then
  fork_rel_status="CURRENT"
else
  fork_rel_status="UPDATE AVAILABLE"
fi
rel_tag_not_default="$(git rev-list --count "$upstream_ref..$tag_commit")"
rel_default_not_tag="$(git rev-list --count "$tag_commit..$upstream_ref")"
if (( rel_tag_not_default == 0 && rel_default_not_tag == 0 )); then
  relation="identical to default branch"
elif (( rel_default_not_tag == 0 )); then
  relation="strictly ahead of default branch (+$rel_tag_not_default commits; merging the tag is a superset of default)"
elif (( rel_tag_not_default == 0 )); then
  relation="behind default branch (default has +$rel_default_not_tag commits the release lacks)"
else
  relation="on a diverged line: +$rel_tag_not_default release-only and +$rel_default_not_tag default-only commits"
fi
log "Latest stable release: $rel_tag @ $tag_commit ($rel_pub) — $fork_rel_status; $relation"

if [[ "$fork_rel_status" == "CURRENT" ]]; then
  log "Release tracking: fork already contains $rel_tag. No proposal."
  exit 0
fi

# Newer prerelease/draft awareness (never proposed as stable).
prerelease_items=""
while IFS=$'\t' read -r pr_tag pr_flag pr_pub; do
  [[ -z "$pr_tag" ]] && continue
  [[ "$pr_flag" == "false" ]] && continue
  if [[ "$pr_pub" > "$rel_pub" ]]; then
    prerelease_items+="$pr_tag ($pr_flag, $pr_pub); "
  fi
done < <(fetch_releases_page | python3 -c '
import json,sys
for r in json.load(sys.stdin):
    print(r.get("tag_name",""), str(r.get("prerelease",False)).lower(), r.get("published_at",""), sep="\t")
')
prerelease_note=""
if [[ -n "$prerelease_items" ]]; then
  log "Newer prereleases exist upstream (not proposed as stable): $prerelease_items"
  prerelease_note="### Newer prereleases (not proposed as stable)
- $prerelease_items"
fi

safe_tag="$(printf '%s' "$rel_tag" | tr -c 'A-Za-z0-9._-' '-')"
rel_branch="sync/upstream-release-$safe_tag"

open_rel_pr="$(open_prs_json | python3 -c '
import json,sys
prs=json.load(sys.stdin)
for p in prs:
    if p["headRefName"].startswith("sync/upstream-release-"):
        print(p["number"], p["headRefName"], p["url"], sep=" "); break
' 2>/dev/null || true)"

if [[ -n "$open_rel_pr" ]]; then
  read -r rel_pr_num rel_pr_head rel_pr_url <<< "$open_rel_pr"
  existing_tag="${rel_pr_head#sync/upstream-release-}"
  if [[ "$existing_tag" == "$safe_tag" ]]; then
    log "Existing release proposal PR #$rel_pr_num already covers $rel_tag ($rel_pr_url). No duplicate."
  else
    if git ls-remote --exit-code --quiet origin "refs/heads/$rel_pr_head"; then
      git fetch --quiet origin "refs/heads/$rel_pr_head:refs/remotes/origin/$rel_pr_head"
      git switch --quiet --detach "refs/remotes/origin/$rel_pr_head"
      if git merge --no-ff --no-edit "$tag_commit" >/dev/null 2>&1; then
        git push --quiet origin "HEAD:refs/heads/$rel_pr_head"
        log "Release proposal PR #$rel_pr_num updated: $existing_tag -> $rel_tag by normal merge (no force-push)."
        pr_comment_once "$rel_pr_num" "rel-update-$tag_commit" \
          "Upstream published stable \`$rel_tag\` (\`$tag_commit\`); proposal branch updated by merge commit. Previous target: \`$existing_tag\`."
      else
        git merge --abort >/dev/null 2>&1 || true
        log "WARN: cannot merge $rel_tag into release proposal PR #$rel_pr_num (target $existing_tag); outdated, manual attention required."
        pr_comment_once "$rel_pr_num" "rel-conflict-$tag_commit" \
          "New stable \`$rel_tag\` (\`$tag_commit\`) does not merge cleanly into this proposal (was \`$existing_tag\`). Left untouched; manual rework required."
      fi
      git switch --quiet --detach "origin/$BRANCH"
    else
      log "WARN: release PR #$rel_pr_num references missing branch $rel_pr_head; skipping (manual cleanup)."
    fi
  fi
  exit 0
fi

# No open release PR: if an open branch-sync proposal already contains the
# tag commit (release cut from the same history), it covers the release.
if [[ -n "$branch_pr" ]]; then
  read -r bpr_num bpr_head _ <<< "$branch_pr"
  if git ls-remote --quiet --exit-code origin "refs/heads/$bpr_head" >/dev/null 2>&1 \
     && git fetch --quiet origin "refs/heads/$bpr_head:refs/remotes/origin/$bpr_head" 2>/dev/null \
     && git merge-base --is-ancestor "$tag_commit" "refs/remotes/origin/$bpr_head"; then
    log "Release tracking: $rel_tag is already covered by open branch-sync PR #$bpr_num; no separate proposal."
    exit 0
  fi
fi

# No open release PR: avoid re-proposing a tag that was already proposed and
# closed without merge (owner rejected or superseded it).
if [[ -n "$(closed_prs_json | python3 -c '
import json,sys
for p in json.load(sys.stdin):
    if p["headRefName"] == "'"$rel_branch"'":
        print(p["number"]); break
' 2>/dev/null || true)" ]]; then
  log "WARN: release $rel_tag was already proposed (branch $rel_branch) and that PR was closed without merge; not re-proposing automatically."
  exit 0
fi

if git ls-remote --quiet --exit-code origin "refs/heads/$rel_branch" >/dev/null 2>&1; then
  log "WARN: branch $rel_branch exists without an open PR; not overwriting. Manual check required."
  exit 0
fi

git switch --quiet -c "$rel_branch" "origin/$BRANCH"
if git merge --no-ff --no-edit "$tag_commit" >/dev/null 2>&1; then
  git push --quiet origin "HEAD:refs/heads/$rel_branch"
  # Category heuristic over the full default->tag diff (review hints, not a verdict).
  categories=""
  diff_files="$(git diff --name-only "origin/$BRANCH" "$tag_commit" || true)"
  grep -q '^\.github/' <<< "$diff_files" && categories+=$'- **workflows/CI changed** — re-check release/CI paths before merge.\n'
  grep -Eq '^(go\.(mod|sum)|package(-lock)?\.json|Cargo\.(toml|lock)|requirements.*\.txt|pom\.xml)' <<< "$diff_files" && categories+=$'- **dependencies changed**.\n'
  grep -Eq '^(LICENSE|NOTICE|COPYRIGHT|COPYING)' <<< "$diff_files" && categories+=$'- **license/notice files changed**.\n'
  grep -Eiq '(^|/)(protocol|wire|auth|token|secret|credential)' <<< "$diff_files" && categories+=$'- **protocol/auth-related paths changed**.\n'
  grep -Eq '^(Dockerfile|docker/|build|deploy|provision|scripts/)' <<< "$diff_files" && categories+=$'- **build/deploy/provision paths changed** — do not run installers from the diff.\n'
  notable="$(grep -E '^\.github/|^(go\.(mod|sum)|Cargo\.toml|package\.json|LICENSE|NOTICE|Dockerfile)' <<< "$diff_files" | head -15 | sed 's|^|  - `|;s|$|`|' || true)"
  body="$(printf '%s\n' \
    "## Review-only upstream release proposal (automated Draft PR)" \
    '' \
    "- Release: [$rel_tag]($rel_url) published $rel_pub" \
    "- Tag commit: \`$tag_commit\` (resolved from tag \`$rel_tag\` fetched from $UPSTREAM_REPO)" \
    "- Relation to upstream default branch ($BRANCH @ \`$upstream_sha\`): $relation" \
    "- Fork base: \`$fork_sha\` — status **$fork_rel_status**" \
    '' \
    '### Upstream release notes (truncated)' \
    '```' \
    "$rel_notes" \
    '```' \
    '' \
    '### Review hints' \
    "${categories:-- (no category flags matched; still review the full diff.)}" \
    '' \
    '### Disclaimers' \
    '- There is NO automatic merge, tag, release, or device deployment.' \
    "- A release tag is proposed even when upstream $BRANCH has not moved (release-vs-main discrepancy is visible above)." \
    '- Merging a Git tag does NOT prove runtime/ARM64/MIPSel compatibility; test after owner review.' \
  )"
  if [[ -n "$prerelease_note" ]]; then
    body="$(printf '%s\n%s\n' "$body" "$prerelease_note")"
  fi
  if [[ -n "$notable" ]]; then
    body="$(printf '%s\n%s\n' "$body" "$(printf '### Notable paths in this diff\n%s' "$notable")")"
  fi
  if ! pr_url="$(create_draft_pr "$rel_branch" \
    "chore(upstream): review release $rel_tag @ ${tag_commit:0:12}" "$body")"; then
    fail "Release branch $rel_branch pushed, but Draft PR creation was blocked (check Actions PR-creation permission)."
  fi
  log "Release proposal Draft PR opened: $pr_url; fork default branch unchanged."
else
  git merge --abort >/dev/null 2>&1 || true
  fail "Release $rel_tag ($tag_commit) conflicts with fork history. No reset, no force-push. Manual merge required."
fi
