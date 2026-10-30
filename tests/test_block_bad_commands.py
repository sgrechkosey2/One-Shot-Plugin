"""Invocation tests for hooks/block-bad-commands.sh (PreToolUse Bash guard).

Each case feeds the hook a Claude Code PreToolUse event on stdin and checks
the exit code: 0 = allowed, 2 = blocked.
"""
import json
import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).parent.parent
HOOK = REPO_ROOT / "hooks" / "block-bad-commands.sh"

CASES = [
    # --- Allowed: commands that only mention the words (the old hook refused these) ---
    ("doc text mentioning the words",
     "cat > notes.md <<'EOF'\nAdd a repository secret named API_TOKEN; never paste credentials.\nEOF", 0),
    ("commit message mentioning the words",
     'git commit -q -m "docs: explain where the repository secret is configured; no credentials in the diff"', 0),
    ("combined short flags with message",
     'git commit -am "secret rotation note"', 0),
    ("workflow file referencing a secrets expression",
     'git add .github/workflows/deploy.yml && git commit -m "deploy uses ${{ secrets.API_TOKEN }} reference only"', 0),
    ("heredoc then git add of a harmless file",
     "cat > f.yml <<'EOF'\nkey: ${{ secrets.X }}\nEOF\ngit add f.yml", 0),
    ("git add then heredoc on a new line",
     "git add README.md\ncat > g.txt <<'EOF'\nsecret words here\nEOF", 0),
    ("non-git command mentioning credentials",
     'python3 scripts/notes.py log "blocked because the message mentioned credentials" --kind NOTE', 0),
    # --- Blocked: staging or committing .env / credential files ---
    ("stage .env", "git add .env", 2),
    ("stage nested .env.local", "git add config/.env.local", 2),
    ("stage credentials.json", "git add credentials.json", 2),
    ("stage client_secret.json", "git add src/client_secret.json", 2),
    ("stage with -C and .env (old hook missed this)", "git -C /tmp/x add .env", 2),
    ("stage after --", "git add -- secret.txt", 2),
    ("commit pathspec .env", 'git commit -m "x" .env', 2),
    ("chained add of .env", "git status && git add src/a.ts .env.production && git commit -m ok", 2),
    # --- Unchanged behaviour of the other guards ---
    ("force push to main (preserved)", "git push --force origin main", 2),
    ("FUTURE_PLAN staging (preserved)", "git add FUTURE_PLAN.md", 2),
    ("ordinary add and commit", 'git add src/lib/a.ts && git commit -m "feat: a"', 0),
]


def run_hook(command: str, plugin_root: Path) -> subprocess.CompletedProcess:
    """Run the hook with a PreToolUse Bash event for `command` on stdin."""
    event = {"tool_name": "Bash", "tool_input": {"command": command}}
    env = os.environ.copy()
    # Point the version-check block at an empty dir so it is a no-op here.
    env["CLAUDE_PLUGIN_ROOT"] = str(plugin_root)
    env["PYTHONIOENCODING"] = "utf-8"
    return subprocess.run(
        ["bash", str(HOOK)],
        input=json.dumps(event),
        capture_output=True,
        text=True,
        env=env,
        cwd=str(REPO_ROOT),
        timeout=30,
    )


@pytest.mark.parametrize("name,command,expected", CASES, ids=[c[0] for c in CASES])
def test_block_bad_commands(name: str, command: str, expected: int, tmp_path: Path) -> None:
    result = run_hook(command, tmp_path)
    assert result.returncode in (0, 2), result.stderr
    assert result.returncode == expected, (
        f"{name}: expected exit {expected}, got {result.returncode}; stderr={result.stderr!r}"
    )


def test_case_count() -> None:
    assert len(CASES) == 18


def test_regression_old_pattern_over_blocked_messages(tmp_path: Path) -> None:
    """The old ungrouped pattern refused any command containing 'secret'/'credentials'."""
    for cmd in ('git commit -m "rotate the secret"', "echo credentials are configured in settings"):
        assert run_hook(cmd, tmp_path).returncode == 0, cmd


def test_regression_old_pattern_missed_git_dash_c(tmp_path: Path) -> None:
    """The old pattern required `git` directly before `add`, so `git -C dir add .env` slipped through."""
    result = run_hook("git -C some/dir add .env", tmp_path)
    assert result.returncode == 2
    assert ".env" in result.stderr
