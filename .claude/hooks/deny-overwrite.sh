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
# It fails open where it cannot decide (no path, a relative path with no cwd, a directory that does not exist, outside any repository):
# it is accident prevention, like the denies, not isolation. A git error inside a repository (dubious ownership, a broken config)
# refuses instead: passing would switch the hook off without anyone noticing.
set -uo pipefail

# One jq call for both fields. @sh keeps a newline in the path from shifting one field into the other
eval "$(jq -r '@sh "path=\(.tool_input.file_path // "") cwd=\(.cwd // "")"' 2>/dev/null)"
[ -n "${path:-}" ] || exit 0
case "${path}" in
  /*) ;;
  *) [ -n "${cwd:-}" ] || exit 0; path="${cwd}/${path}" ;;
esac

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

# tracked <path>: 0 if git tracks it, 1 if not (or no repository / no directory), 2 if git failed (the error in git_err)
git_err=""
tracked() {
  local dir magic
  dir=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd) || return 1
  git_err=$(LC_ALL=C git -C "${dir}" rev-parse --git-dir 2>&1 >/dev/null) || {
    case "${git_err}" in *"not a git repository"*) return 1 ;; *) return 2 ;; esac
  }
  # literal: a name with [ ] * ? is not a glob. icase where git says the file system ignores case (the macOS default),
  # so that readme.md does not get past a tracked README.md
  magic=literal
  [ "$(git -C "${dir}" config --bool core.ignorecase 2>/dev/null)" = true ] && magic=literal,icase
  git_err=$(LC_ALL=C git -C "${dir}" ls-files --error-unmatch -- ":(${magic})$(basename "$1")" 2>&1 >/dev/null)
  case $? in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
}

check() {
  tracked "$1"
  case $? in
    0)
      if [ -e "$1" ] || [ -L "$1" ]; then
        deny "$1 is tracked by git, so Write may not rewrite it. Change an existing file with Edit: copying its contents through Write breaks lines you did not mean to change (escapes are not kept, and a long file gets cut). If an Edit does not match, Read those lines again and retry with a shorter old_string that is still unique."
      fi
      deny "$1 is tracked by git but missing from the working tree, so Write may not recreate it: a file written from memory is not the one git has. Do not recreate it another way; say in your report that it is missing."
      ;;
    2) deny "Could not check whether $1 is tracked by git, so Write is refused (git: $(printf '%s' "${git_err}" | head -n 1)). Say so in your report; a human needs to fix the repository." ;;
  esac
}

# Check every name along a chain of symlinks, then the target: a tracked link would be replaced, and an untracked link to
# a tracked file would rewrite it. A chain longer than 10 is refused, since what it ends at is not checked
hops=0
while :; do
  check "${path}"
  [ -L "${path}" ] || exit 0
  hops=$((hops + 1))
  [ "${hops}" -le 10 ] || deny "${path} is reached through more than 10 symlinks, so Write is refused. Write to the file itself."
  link=$(readlink "${path}") || exit 0
  case "${link}" in
    /*) path="${link}" ;;
    *) path="$(dirname "${path}")/${link}" ;;
  esac
done
