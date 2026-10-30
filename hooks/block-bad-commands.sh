#!/bin/bash
# PreToolUse hook: block dangerous bash commands
#
# Claude Code hooks receive event JSON on stdin (not via $CLAUDE_TOOL_INPUT).
# Reference: https://docs.anthropic.com/en/docs/claude-code/hooks

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null)

# Block FUTURE_PLAN.md commit (local-only file, should never be pushed)
if echo "$COMMAND" | grep -qE "git\s+(add|commit).*FUTURE_PLAN"; then
  echo "ERROR: FUTURE_PLAN.md is local only (gitignored). Do not commit it." >&2
  exit 2
fi

# Block git commit if plugin.json version doesn't match CHANGELOG
if echo "$COMMAND" | grep -qE "git\s+commit"; then
  PLUGIN_VERSION=$(grep -o '"version"\s*:\s*"[^"]*"' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" 2>/dev/null | cut -d'"' -f4)
  CHANGELOG_VERSION=$(head -5 "${CLAUDE_PLUGIN_ROOT}/CHANGELOG.md" 2>/dev/null | grep -o "v[0-9.]*" | head -1)

  if [ -n "$PLUGIN_VERSION" ] && [ -n "$CHANGELOG_VERSION" ]; then
    if [ "$PLUGIN_VERSION" != "${CHANGELOG_VERSION#v}" ]; then
      echo "ERROR: plugin.json version ($PLUGIN_VERSION) != CHANGELOG.md version (${CHANGELOG_VERSION#v}). Bump one before committing." >&2
      exit 2
    fi
  fi
fi

# Block committing .env or secrets.
# Only the PATH arguments of `git add` / `git commit` are inspected: the command is
# tokenized with shlex, global git options such as `-C <dir>` are skipped, and
# commit-message options (-m, -F, --message, combined short flags like -am, ...)
# are ignored. A path is refused when it names a .env file (.env, .env.*, */.env*)
# or contains "credentials" or "secret" (case-insensitive). Commands that merely
# mention those words (docs, heredocs, commit messages, workflow files that
# reference ${{ secrets.X }}) are not blocked.
# The previous single pattern, git\s+(add|commit).*\.env|credentials|secret, had an
# ungrouped alternation: it matched "credentials"/"secret" anywhere in any command
# and missed `git -C <dir> add .env`.
if echo "$COMMAND" | grep -qE "git\s"; then
  BLOCKED_PATH=$(printf '%s' "$COMMAND" | python3 -c '
import re, shlex, sys
cmd = sys.stdin.read()
pat = re.compile(r"(^|/)\.env($|\.)|credentials|secret", re.I)
lex = shlex.shlex(cmd, posix=True, punctuation_chars=";&|\n")
lex.whitespace = " \t\r"
lex.whitespace_split = True
try:
    toks = list(lex)
except ValueError:
    toks = cmd.split()
def is_sep(t):
    return t != "" and set(t) <= set(";&|\n")
msg_opts = {"-m", "--message", "-F", "--file", "-C", "--reuse-message", "-c", "--reedit-message", "--author",
            "--date", "--fixup", "--squash", "-t", "--template", "--trailer", "--pathspec-from-file"}
hit = ""
i = 0
while i < len(toks) and not hit:
    if toks[i] != "git":
        i += 1
        continue
    j = i + 1
    while j < len(toks) and toks[j].startswith("-"):
        j += 2 if toks[j] in ("-C", "-c", "--git-dir", "--work-tree") else 1
    if j >= len(toks) or toks[j] not in ("add", "commit"):
        i = j
        continue
    sub, k = toks[j], j + 1
    while k < len(toks) and not is_sep(toks[k]):
        t = toks[k]
        if sub == "commit" and (t in msg_opts or re.match(r"^-[A-Za-z]*[mFCct]$", t)):
            k += 2
            continue
        if t.startswith("-") or t.startswith("<") or t.startswith(">"):
            k += 1
            continue
        if pat.search(t):
            hit = t
            break
        k += 1
    i = k
print(hit)
' 2>/dev/null)
  if [ -n "$BLOCKED_PATH" ]; then
    echo "ERROR: Do not commit .env files or credentials. These must be local-only. (path: $BLOCKED_PATH)" >&2
    exit 2
  fi
fi

# Block force push to main
if echo "$COMMAND" | grep -qE "git\s+push.*--force.*main|git\s+push.*-f.*main"; then
  echo "ERROR: Force push to main is blocked. Use a PR or ask repo owner." >&2
  exit 2
fi

exit 0
