#!/usr/bin/env bash
# anthropic-scout-scan.sh
# Fetches current Anthropic repo state, compares against last scan,
# outputs a diff report for the scout agent to interpret.
#
# Usage: bash scripts/anthropic-scout-scan.sh
# Output: JSON diff to stdout

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$PROJECT_ROOT/store/anthropic-scout-state.json"
CURRENT_FILE="/tmp/anthropic-scout-current-$(date +%s).json"

# Fetch all repos from anthropics org
gh api orgs/anthropics/repos --paginate \
  --jq '[.[] | {name, description, pushed_at, created_at, topics, language, archived, fork, stargazers_count, open_issues_count}]' \
  > "$CURRENT_FILE" 2>/dev/null

if [ ! -f "$STATE_FILE" ]; then
  echo '{"status": "first_run", "repo_count": '$(python3 -c "import json; print(len(json.load(open('$CURRENT_FILE'))))")'}'
  cp "$CURRENT_FILE" "$STATE_FILE"
  # Also output current state for first-run report
  cat "$CURRENT_FILE"
  exit 0
fi

# Compare previous and current state
python3 -c "
import json, sys
from datetime import datetime

with open('$STATE_FILE') as f:
    prev = json.load(f)
with open('$CURRENT_FILE') as f:
    curr = json.load(f)

prev_map = {r['name']: r for r in prev}
curr_map = {r['name']: r for r in curr}

prev_names = set(prev_map.keys())
curr_names = set(curr_map.keys())

new_repos = []
for name in sorted(curr_names - prev_names):
    r = curr_map[name]
    new_repos.append({
        'name': name,
        'description': r.get('description'),
        'created_at': r.get('created_at'),
        'language': r.get('language'),
        'topics': r.get('topics', []),
        'fork': r.get('fork', False),
    })

removed_repos = sorted(prev_names - curr_names)

updated_repos = []
for name in sorted(curr_names & prev_names):
    p = prev_map[name]
    c = curr_map[name]
    if p.get('pushed_at') != c.get('pushed_at'):
        updated_repos.append({
            'name': name,
            'description': c.get('description'),
            'prev_pushed_at': p.get('pushed_at'),
            'curr_pushed_at': c.get('pushed_at'),
            'language': c.get('language'),
            'topics': c.get('topics', []),
            'stars': c.get('stargazers_count', 0),
        })
    elif p.get('description') != c.get('description'):
        updated_repos.append({
            'name': name,
            'description': c.get('description'),
            'prev_description': p.get('description'),
            'change_type': 'description_changed',
        })
    elif p.get('topics') != c.get('topics'):
        updated_repos.append({
            'name': name,
            'prev_topics': p.get('topics', []),
            'curr_topics': c.get('topics', []),
            'change_type': 'topics_changed',
        })

result = {
    'scan_date': datetime.utcnow().isoformat() + 'Z',
    'total_repos': len(curr),
    'new_repos': new_repos,
    'removed_repos': removed_repos,
    'updated_repos': updated_repos,
    'unchanged_count': len(curr_names & prev_names) - len(updated_repos),
}

print(json.dumps(result, indent=2))
"

# Update state file
cp "$CURRENT_FILE" "$STATE_FILE"
rm -f "$CURRENT_FILE"
