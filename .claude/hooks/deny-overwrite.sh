#!/bin/bash
# PreToolUse hook for Write: refuses to rewrite a file that git tracks (#58). merge-permissions.sh adds it to every profile.
# Input: the hook JSON on standard input. Output: a deny decision as JSON, or nothing (the call goes on to the permission rules).
#
# Write rules with a path never match (A4 in docs/setup.md §6), so the permission lists cannot say this. Copying an existing file
# through Write's argument does not reproduce it (A3: escapes such as “ come back as the raw character, and a long file hits the
# output limit and gets cut), and agents did so even when the instruction document named the file and forbade it.
# New files, the flow's tmp/ (gitignored) and files the agent created earlier (untracked) are not tracked, so they pass.
#
# It lives under .claude/ because Claude Code itself blocks writes there (B1): an agent cannot switch it off during the step.
# It fails open (anything unexpected lets the call through): it is accident prevention, like the denies, not isolation.
set -uo pipefail

# One jq call for both fields. A relative path with no cwd to resolve it against cannot be checked, so it passes
{ IFS= read -r path; IFS= read -r cwd; } < <(jq -r '(.tool_input.file_path // ""), (.cwd // "")' 2>/dev/null)
[ -n "${path:-}" ] || exit 0
case "${path}" in
  /*) ;;
  *) [ -n "${cwd:-}" ] || exit 0; path="${cwd}/${path}" ;;
esac
# Follow symlinks, so that a Write through an untracked link to a tracked file is checked as the target (bounded, in case of a loop)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -L "${path}" ] || break
  link=$(readlink "${path}") || exit 0
  case "${link}" in
    /*) path="${link}" ;;
    *) path="$(dirname "${path}")/${link}" ;;
  esac
done
[ -f "${path}" ] || exit 0
dir=$(cd -P "$(dirname "${path}")" 2>/dev/null && pwd) || exit 0
# literal: a name with [ ] * ? is not a glob. icase where git says the file system ignores case (the macOS default),
# so that readme.md does not get past a tracked README.md
magic=literal
[ "$(git -C "${dir}" config --bool core.ignorecase 2>/dev/null)" = true ] && magic=literal,icase
git -C "${dir}" ls-files --error-unmatch -- ":(${magic})$(basename "${path}")" >/dev/null 2>&1 || exit 0

jq -n --arg p "${path}" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
  permissionDecisionReason: ("\($p) is tracked by git, so Write may not rewrite it. Change an existing file with Edit: copying its contents through Write breaks lines you did not mean to change (escapes are not kept, and a long file gets cut). If an Edit does not match, Read those lines again and retry with a shorter old_string that is still unique.")}}'
