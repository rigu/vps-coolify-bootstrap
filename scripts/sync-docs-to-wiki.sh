#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# sync-docs-to-wiki.sh — Convert docs/ pages into GitHub Wiki format
#
# Usage:
#   bash scripts/sync-docs-to-wiki.sh [--output-dir <path>]
#
# Default output: wiki/ (at repo root)
# After running, push the output directory to the wiki repo:
#   cd wiki && git init && git remote add origin git@github.com:rigu/vps-coolify-bootstrap.wiki.git
#   git add -A && git commit -m "sync wiki from docs" && git push -u origin master --force
# ---------------------------------------------------------------------------

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
docs_dir="$repo_root/docs"
output_dir="$repo_root/wiki"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: bash scripts/sync-docs-to-wiki.sh [--output-dir <path>]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

rm -rf "$output_dir"
mkdir -p "$output_dir"

# Map of docs filename -> wiki page name
declare -A page_map=(
  ["index.md"]="Home"
  ["getting-started.md"]="Getting-Started"
  ["onboarding-troubleshooting.md"]="Onboarding-Troubleshooting"
  ["create-infra-network.md"]="Create-Infra-Network"
  ["install-docmost-on-coolify.md"]="Install-Docmost-on-Coolify"
  ["install-plane-on-coolify.md"]="Install-Plane-on-Coolify"
  ["backup-strategy.md"]="Backup-Strategy"
  ["maintenance-runbook.md"]="Maintenance-Runbook"
  ["scripts-workflow.md"]="Script-Workflow"
  ["bootstrap-env-reference.md"]="Bootstrap-Env-Reference"
  ["bootstrap-flow.md"]="Bootstrap-Flow"
  ["vps-coolify-deployment-modes.md"]="Deployment-Modes"
  ["vps-coolify-realtime-modes.md"]="Realtime-Modes"
  ["operations-security.md"]="Operations-and-Security"
  ["bootstrap-failure-recovery.md"]="Bootstrap-Failure-Recovery"
  ["plane-community-v1.2.3-incident-prevention.md"]="Plane-Incident-Prevention"
  ["github-promotion.md"]="GitHub-Promotion"
)

# Process each doc file
for src_file in "$docs_dir"/*.md; do
  basename_file="$(basename "$src_file")"

  # Skip config
  [[ "$basename_file" == "_config.yml" ]] && continue

  wiki_name="${page_map[$basename_file]:-}"
  if [[ -z "$wiki_name" ]]; then
    echo "SKIP: $basename_file (no wiki mapping)" >&2
    continue
  fi

  dest_file="$output_dir/$wiki_name.md"

  # Strip YAML front-matter
  awk '
    BEGIN { in_front=0; done_front=0 }
    /^---$/ && !done_front { in_front=!in_front; if(!in_front) done_front=1; next }
    in_front { next }
    { print }
  ' "$src_file" > "$dest_file.tmp"

  # Convert internal links: [text](file.md) -> [[wiki-page-name]]
  # and [text](file.md#anchor) -> [[wiki-page-name|text]]
  content="$(cat "$dest_file.tmp")"

  # Replace links to known docs pages with wiki links
  for doc_name in "${!page_map[@]}"; do
    wiki_target="${page_map[$doc_name]}"
    # [text](filename.md#anchor) -> [text](wiki-page-name#anchor)
    content="$(echo "$content" | sed "s|]($doc_name#|]($wiki_target#|g")"
    # [text](filename.md) -> [text](wiki-page-name)
    content="$(echo "$content" | sed "s|]($doc_name)|]($wiki_target)|g")"
  done

  # Write final content, strip leading blank lines
  echo "$content" | sed '/./,$!d' > "$dest_file"
  rm -f "$dest_file.tmp"

  echo "OK: $basename_file -> $wiki_name.md"
done

# Generate _Sidebar.md
cat > "$output_dir/_Sidebar.md" << 'SIDEBAR'
**Getting Started**

- [[Home]]
- [[Getting Started|Getting-Started]]
- [[Onboarding Troubleshooting|Onboarding-Troubleshooting]]

**Deploy Workloads**

- [[Create Infra Network|Create-Infra-Network]]
- [[Install Docmost|Install-Docmost-on-Coolify]]
- [[Install Plane|Install-Plane-on-Coolify]]

**Operations**

- [[Backup Strategy|Backup-Strategy]]
- [[Maintenance Runbook|Maintenance-Runbook]]
- [[Operations & Security|Operations-and-Security]]
- [[Deployment Modes|Deployment-Modes]]
- [[Realtime Modes|Realtime-Modes]]

**Reference**

- [[Script Workflow|Script-Workflow]]
- [[Bootstrap Env Reference|Bootstrap-Env-Reference]]
- [[Bootstrap Flow|Bootstrap-Flow]]
- [[Failure Recovery|Bootstrap-Failure-Recovery]]
- [[Plane Incident Prevention|Plane-Incident-Prevention]]

**Maintainer**

- [[GitHub Promotion|GitHub-Promotion]]
SIDEBAR

# Generate _Footer.md
cat > "$output_dir/_Footer.md" << 'FOOTER'
---
[Documentation Site](https://rigu.github.io/vps-coolify-bootstrap/) · [Repository](https://github.com/rigu/vps-coolify-bootstrap) · License: MIT
FOOTER

echo ""
echo "Wiki pages generated in: $output_dir"
echo "Total pages: $(find "$output_dir" -name '*.md' | wc -l)"
echo ""
echo "Next steps:"
echo "  1. Enable Wiki in GitHub repo Settings -> Features -> Wikis"
echo "  2. Create first page via GitHub UI (initializes wiki repo)"
echo "  3. Clone wiki repo:"
echo "     git clone git@github.com:rigu/vps-coolify-bootstrap.wiki.git /tmp/vps-wiki"
echo "  4. Copy generated pages:"
echo "     cp $output_dir/*.md /tmp/vps-wiki/"
echo "  5. Push:"
echo "     cd /tmp/vps-wiki && git add -A && git commit -m 'sync wiki from docs' && git push"
