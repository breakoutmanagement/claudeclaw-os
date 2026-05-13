# GitHub Skill

Interact with GitHub repositories using the `gh` CLI. Use this skill for issues, PRs, reviews, releases, and repo management.

## Prerequisites

- `gh` CLI installed at `~/bin/gh` (add to PATH: `export PATH="$HOME/bin:$PATH"`)
- Authenticated: `gh auth login` (use a Personal Access Token with `repo` scope)

## Common operations

### Issues

```bash
# List open issues
gh issue list --repo OWNER/REPO

# View issue details
gh issue view NUMBER --repo OWNER/REPO

# Create issue
gh issue create --repo OWNER/REPO --title "Title" --body "Description"

# Close issue
gh issue close NUMBER --repo OWNER/REPO

# Add labels
gh issue edit NUMBER --repo OWNER/REPO --add-label "bug,priority:high"

# Search issues
gh issue list --repo OWNER/REPO --search "keyword"
```

### Pull Requests

```bash
# List open PRs
gh pr list --repo OWNER/REPO

# View PR details
gh pr view NUMBER --repo OWNER/REPO

# View PR diff
gh pr diff NUMBER --repo OWNER/REPO

# Create PR
gh pr create --repo OWNER/REPO --title "Title" --body "Description" --base main

# Review PR
gh pr review NUMBER --repo OWNER/REPO --approve --body "LGTM"
gh pr review NUMBER --repo OWNER/REPO --request-changes --body "See comments"
gh pr review NUMBER --repo OWNER/REPO --comment --body "Feedback"

# View PR checks/CI status
gh pr checks NUMBER --repo OWNER/REPO

# Merge PR
gh pr merge NUMBER --repo OWNER/REPO --squash --delete-branch

# View PR comments
gh api repos/OWNER/REPO/pulls/NUMBER/comments
```

### Branches

```bash
# List branches
gh api repos/OWNER/REPO/branches --jq '.[].name'

# Create branch from main
git checkout -b feat/my-feature origin/main

# Push branch
git push -u origin feat/my-feature
```

### Releases

```bash
# List releases
gh release list --repo OWNER/REPO

# Create release
gh release create v1.0.0 --repo OWNER/REPO --title "v1.0.0" --notes "Release notes"
```

### Repository info

```bash
# View repo details
gh repo view OWNER/REPO

# List repo topics
gh api repos/OWNER/REPO/topics

# Clone repo
gh repo clone OWNER/REPO
```

### Advanced API calls

```bash
# Any GitHub REST API endpoint
gh api repos/OWNER/REPO/commits --jq '.[0:5] | .[].commit.message'

# GraphQL query
gh api graphql -f query='{ repository(owner:"OWNER", name:"REPO") { issues(first:5) { nodes { title number } } } }'

# Paginated results
gh api repos/OWNER/REPO/issues --paginate --jq '.[].title'
```

## Target repos

The primary repo for the dev team is:
- `breakoutmanagement/breakoutwithai-3d` - Main product repo

Always use `--repo OWNER/REPO` flag to avoid depending on the current directory's git remote.

## Notes

- Always use `export PATH="$HOME/bin:$PATH"` before running gh commands
- Use `--jq` for filtering JSON output
- Use `--json` to specify which fields to return
- PR descriptions should include: what changed, why, and how to test
- For large diffs, use `gh pr diff NUMBER | head -200` to preview
