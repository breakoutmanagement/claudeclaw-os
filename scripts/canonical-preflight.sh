#!/usr/bin/env bash
# canonical-preflight.sh
# Pre-flight check before opening or pushing a PR that touches CANONICAL.md / DEPLOY.md
# or any other "source-of-truth" doc.
#
# Catches the failure mode where target state gets written as current state.
#
# Three gates:
#   1. PR_STATE: every PR number named in the diff has its real state verified
#                via `gh pr view --json state,mergedAt`. Wording mismatch = block.
#   2. URL_LIVE: every URL written as a *runtime* value in the diff is curled.
#                Non-2xx/3xx = block unless wording flags it as target/future.
#   3. UNVERIFIED_CLAIMS: scans the diff for state keywords (MERGED, LIVE, ACTIVE,
#                CANONICAL, LIVE NOW, DEPLOYED) adjacent to tokens not verified
#                by gates 1 or 2. Soft warn.
#
# Usage:
#   canonical-preflight.sh [--repo <owner/name>] [--base <branch>] [--paths "glob1 glob2"]
#
# Defaults:
#   --repo   inferred from `gh repo view`
#   --base   origin/main
#   --paths  "CANONICAL.md apps/*/DEPLOY.md docs/ways-of-working/*.md"
#
# Exit codes:
#   0 = all gates pass
#   1 = blocking gate failed (PR_STATE or URL_LIVE)
#   2 = soft warn only (UNVERIFIED_CLAIMS)
#   3 = usage / environment error

set -uo pipefail

REPO=""
BASE="origin/main"
PATHS="CANONICAL.md apps/*/DEPLOY.md docs/ways-of-working/*.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="$2"; shift 2 ;;
    --base)  BASE="$2"; shift 2 ;;
    --paths) PATHS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 3 ;;
  esac
done

command -v gh   >/dev/null 2>&1 || { echo "gh not on PATH" >&2; exit 3; }
command -v git  >/dev/null 2>&1 || { echo "git not on PATH" >&2; exit 3; }
command -v curl >/dev/null 2>&1 || { echo "curl not on PATH" >&2; exit 3; }
# rg is optional — only used for ad-hoc inspection; grep is the hard dep
command -v grep >/dev/null 2>&1 || { echo "grep not on PATH" >&2; exit 3; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "not inside a git repo" >&2; exit 3;
}

if [[ -z "$REPO" ]]; then
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    echo "could not infer repo; pass --repo owner/name" >&2; exit 3;
  }
fi

# Resolve diff scope. If base is unreachable, fall back to HEAD~1.
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "base $BASE not found; falling back to HEAD~1" >&2
  BASE="HEAD~1"
fi

# Filter to relevant paths.
mapfile -t CHANGED < <(git diff --name-only "$BASE"...HEAD -- $PATHS 2>/dev/null)
if [[ ${#CHANGED[@]} -eq 0 ]]; then
  echo "preflight: no canonical-truth docs touched between $BASE and HEAD. nothing to check."
  exit 0
fi

echo "preflight: checking diff in:"
printf '  %s\n' "${CHANGED[@]}"
echo

DIFF=$(git diff "$BASE"...HEAD -- "${CHANGED[@]}")
ADDED=$(printf '%s\n' "$DIFF" | grep -E '^\+[^+]' || true)

FAIL=0
WARN=0
VERIFIED_PRS=""  # space-separated list of PR numbers whose state matched the diff wording

# ──────────────────────────────────────────────────────────────────────────────
# Gate 1: PR_STATE
# ──────────────────────────────────────────────────────────────────────────────
echo "── gate 1: PR_STATE ──────────────────────────────────────────────"
mapfile -t PR_NUMS < <(printf '%s\n' "$ADDED" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)

if [[ ${#PR_NUMS[@]} -eq 0 ]]; then
  echo "  no PR numbers referenced in additions."
else
  for n in "${PR_NUMS[@]}"; do
    # Ignore plausible non-PR refs (issues with the same #N format are checked
    # the same way; gh handles both endpoints, so worst case we fetch issue state).
    META=$(gh pr view "$n" --repo "$REPO" --json state,mergedAt,number 2>/dev/null)
    if [[ -z "$META" ]]; then
      echo "  #$n: not a PR in $REPO (possibly an issue ref). skipping."
      continue
    fi
    STATE=$(printf '%s' "$META" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("state",""))')
    MERGED_AT=$(printf '%s' "$META" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("mergedAt") or "")')

    # Find wording adjacent to #N in additions (single-line context).
    CONTEXT=$(printf '%s\n' "$ADDED" | grep -E "#$n([^0-9]|$)" || true)

    # Check claims-vs-reality.
    BAD=0
    if [[ "$STATE" != "MERGED" ]]; then
      if printf '%s' "$CONTEXT" | grep -qiE "#$n[^0-9].*\bMERGED\b|\bMERGED\b.*#$n"; then
        echo "  ✗ #$n claims MERGED but actual state is $STATE"
        BAD=1
      fi
    fi
    if [[ "$STATE" != "OPEN" ]]; then
      if printf '%s' "$CONTEXT" | grep -qiE "#$n[^0-9].*\bOPEN\b|\bOPEN\b.*#$n"; then
        echo "  ✗ #$n claims OPEN but actual state is $STATE"
        BAD=1
      fi
    fi
    if [[ $BAD -eq 0 ]]; then
      echo "  ✓ #$n state=$STATE matches diff wording"
      VERIFIED_PRS="$VERIFIED_PRS $n"
    else
      FAIL=1
    fi
  done
fi
echo

# ──────────────────────────────────────────────────────────────────────────────
# Gate 2: URL_LIVE
#   Only checks URLs in lines that look like runtime/config assignments,
#   not URLs in prose tables (those are reference, not runtime).
#   Heuristic: lines containing `=` or `--app` or starting with a bash code block.
# ──────────────────────────────────────────────────────────────────────────────
echo "── gate 2: URL_LIVE ──────────────────────────────────────────────"

# Extract URLs from runtime-flavoured added lines.
RUNTIME_LINES=$(printf '%s\n' "$ADDED" | grep -E '=|--app|export ' || true)
mapfile -t URLS < <(printf '%s\n' "$RUNTIME_LINES" \
  | grep -oE 'https?://[A-Za-z0-9._/-]+' \
  | grep -vE 'localhost|127\.0\.0\.1|example\.com' \
  | sort -u)

if [[ ${#URLS[@]} -eq 0 ]]; then
  echo "  no runtime URLs in diff."
else
  for u in "${URLS[@]}"; do
    # Check if wording flags this URL as target/future/post-CNAME — if so, skip.
    # Only skip if the URL is clearly tagged as target-not-yet-live, not just
    # mentioned in migration prose. "transitional" / "until" describe behaviour,
    # not non-existence, so don't skip on those.
    if printf '%s\n' "$ADDED" | grep -F -- "$u" | grep -qiE '\b(target|future|post-cname|aspirational|planned|tbd|not yet live)\b'; then
      echo "  ◦ $u flagged as target/future. skipping live-check."
      continue
    fi
    # Reduce to host origin — path liveness depends on app routes (e.g. OAuth
    # callbacks 503 without state). The drift we're catching is "this host
    # doesn't exist / doesn't route", not "this path 404s".
    ORIGIN=$(printf '%s' "$u" | sed -E 's|^(https?://[^/]+).*|\1|')
    CODE=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 6 -L "$ORIGIN" 2>/dev/null || echo "000")
    # Accept 2xx, 3xx, 4xx (host responded, app just doesn't serve that path).
    # Reject 5xx, 000, DNS failures.
    if [[ "$CODE" =~ ^(2|3|4)[0-9][0-9]$ ]]; then
      echo "  ✓ $u (origin $ORIGIN → $CODE)"
    else
      echo "  ✗ $u → $CODE on origin $ORIGIN (host does not route)"
      FAIL=1
    fi
  done
fi
echo

# ──────────────────────────────────────────────────────────────────────────────
# Gate 3: UNVERIFIED_CLAIMS (soft warn)
# ──────────────────────────────────────────────────────────────────────────────
echo "── gate 3: UNVERIFIED_CLAIMS (warn) ─────────────────────────────"
RAW_SUSPECT=$(printf '%s\n' "$ADDED" \
  | grep -nE '\b(MERGED|LIVE|ACTIVE|DEPLOYED)\b' \
  | grep -vE '\bnot\b|\bnever\b|\baspirational\b|\btarget\b|\bfuture\b|\bnot yet\b|\bplanned\b|\btransitional\b|\bpost-cname\b|\btbd\b' \
  || true)

# Filter out lines whose only state claim is for a PR already verified in gate 1.
SUSPECT=""
if [[ -n "$RAW_SUSPECT" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Extract PR numbers on the line.
    line_prs=$(printf '%s' "$line" | grep -oE '#[0-9]+' | tr -d '#' || true)
    all_verified=1
    has_pr=0
    for p in $line_prs; do
      has_pr=1
      case " $VERIFIED_PRS " in
        *" $p "*) ;;
        *) all_verified=0 ;;
      esac
    done
    # Keep the line only if it has no PR refs (so a bare MERGED/LIVE claim) or
    # at least one PR ref that wasn't verified in gate 1.
    if [[ $has_pr -eq 0 || $all_verified -eq 0 ]]; then
      SUSPECT="${SUSPECT}${line}"$'\n'
    fi
  done <<< "$RAW_SUSPECT"
fi

if [[ -z "$SUSPECT" ]]; then
  echo "  no unverified state claims found."
else
  echo "  state-keyword hits below — confirm each is backed by gate 1 or 2:"
  printf '%s' "$SUSPECT" | sed 's/^/    /'
  WARN=1
fi
echo

# ──────────────────────────────────────────────────────────────────────────────
echo "── summary ──────────────────────────────────────────────────────"
if [[ $FAIL -eq 1 ]]; then
  echo "  BLOCKED: fix failing gates above before opening PR."
  exit 1
fi
if [[ $WARN -eq 1 ]]; then
  echo "  WARN: passed hard gates; review unverified claims above."
  exit 2
fi
echo "  PASS: canonical-doc preflight green."
exit 0
