#!/bin/bash
# Adds the project's extra permissions to a permission profile (the base every project uses) and prints the result.
# Usage: ./scripts/merge-permissions.sh <base profile>
#
# The project's additions are the allow / deny lists in .ai-flow/permissions.json (both optional).
# claude-run.sh writes the result to a temporary file each time it starts claude and passes it with --settings.
# The merged result is not kept in ai-flow/tmp/ or elsewhere: an agent could rewrite it to widen the permissions of the
# next step (tmp/ is gitignored, so run-phase.sh's working tree check would not see it).
# The source of the additions (.ai-flow/) is protected by TOOLING_PATHS in run-phase.sh.
#
# It also adds the PreToolUse hook that refuses Write to files git tracks (.claude/hooks/deny-overwrite.sh, #58) to every profile,
# with an absolute path: an agent's `cd` persists (A2 in docs/setup.md §6), so a relative one could stop resolving mid-step.
# It is run with bash, so that a copy that lost its executable bit (a zip, core.fileMode=false) still works.
set -uo pipefail

BASE="${1:?a base permission profile is required}"
PROJECT_DIR="${AI_FLOW_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)/.ai-flow}"
EXTRA="${PROJECT_DIR}/permissions.json"

HOOK="$(cd "$(dirname "$0")/.." && pwd -P)/.claude/hooks/deny-overwrite.sh"
[ -f "$HOOK" ] || { echo "Error: merge-permissions.sh: $HOOK not found." >&2; exit 1; }

for f in "$BASE" "$EXTRA"; do
  [ -f "$f" ] || { echo "Error: merge-permissions.sh: $f not found." >&2; exit 1; }
  jq -e . "$f" >/dev/null 2>&1 || { echo "Error: merge-permissions.sh: $f is not valid JSON." >&2; exit 1; }
done

jq -s --arg hook "$HOOK" '
  .[0] as $base | .[1] as $extra
  | $base
  | .permissions.allow = (($base.permissions.allow // []) + ($extra.allow // []) | unique)
  | .permissions.deny = (($base.permissions.deny // []) + ($extra.deny // []) | unique)
  | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{matcher: "Write", hooks: [{type: "command", command: ("bash " + ($hook | @sh))}]}])
' "$BASE" "$EXTRA"
