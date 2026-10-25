#!/usr/bin/env python3
"""Claude Code "Stop" hook: continue a turn the local model abandoned.

A local model behind Claude Code sometimes answers with a preamble -- "Let me
read the plan and check what's already done." -- and ends the turn with
stop_reason "end_turn" and no tool_use block. The CLI takes that as a finished
answer and waits for you, so the task stops after one sentence and looks like a
broken gateway. It is not: the same request, replayed, usually does call the
tool. This hook is the retry.

Registered in ~/.claude/settings.json:

    "hooks": { "Stop": [ { "hooks": [
        { "type": "command",
          "command": "python3 ~/.config/claude-strata/claude-stall-guard.py" }
    ] } ] }

Claude Code pipes the hook a JSON object on stdin:

    {"session_id", "transcript_path", "cwd", "hook_event_name": "Stop",
     "stop_hook_active": false}

Printing {"decision": "block", "reason": "..."} keeps the agent running and
hands "reason" back to the model as the instruction to follow. Anything else
(exit 0, no output) lets the turn end.

Only obvious announcements are blocked, and only once: on the second Stop of
the same turn stop_hook_active is true, so a model that announces again simply
gets its turn ended, the way it would without this hook.
"""

import json
import os
import re
import sys

# "Let me read the plan..." / "I'll check what's done" / "Now let me open..."
# Deliberately narrow: words that mostly precede a real answer ("Okay, the plan
# has four sections") are left out, because blocking one of those makes the
# model answer the same question twice.
ANNOUNCES = re.compile(
    r"""^\s*(?:\x23+\s*)?                        # optional heading marker
        (?:(?:first|next|now|so|alright|okay|ok)[,.]?\s+)?   # "First, let me…"
        (?:let\s+(?:me|us)\b|let(?:'|’)?s\b
          |i(?:'|’)?ll\b|i\s+will\b|i\s+shall\b
          |i(?:'|’)?m\s+(?:going|about)\s+to\b
          |i\s+(?:need|have|ought)\s+to\b
          |i\s+start\b|i\s+open\b|i\s+read\b|i\s+check\b|i\s+look\b
          |going\s+to\b|time\s+to\b|here(?:'|’)?s\s+how\b)
     """,
    re.IGNORECASE | re.VERBOSE,
)

# A real answer can start that way too; a wall of text almost never does, it
# would have said the thing instead of promising to.
MAX_ANNOUNCE_CHARS = 600

REASON = (
    "You ended the turn by announcing a step but did not call any tool, so "
    "nothing happened. Do that step now: make the tool call you just described. "
    "Skip the preamble."
)


def last_assistant(rows):
    """The newest assistant reply, or None.

    Claude Code writes one transcript row per streamed content block, so a
    reply that thought, then spoke, then called a tool is three rows sharing a
    message id. Read them as one message or a tool call in an earlier row is
    invisible and a finished turn looks like a stall.
    """
    blocks, seen, wanted = [], False, None
    for r in reversed(rows):
        if r.get("type") != "assistant":
            if seen:
                break
            continue
        msg = r.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        mid = msg.get("id")
        if not seen:
            seen, wanted = True, mid
        elif mid and wanted and mid != wanted:
            break                          # previous reply
        blocks = content + blocks
    return {"content": blocks} if blocks else None


def text_of(msg):
    return "".join(
        b.get("text", "")
        for b in msg["content"]
        if isinstance(b, dict) and b.get("type") == "text"
    ).strip()


def should_block(msg):
    """True when this assistant turn is an unfulfilled promise."""
    if any(b.get("type") == "tool_use" for b in msg["content"] if isinstance(b, dict)):
        return False                       # it acted; a normal stop
    text = text_of(msg)
    if not text or len(text) > MAX_ANNOUNCE_CHARS:
        return False
    return bool(ANNOUNCES.match(text))


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0                           # not our protocol, not our problem
    if payload.get("hook_event_name") != "Stop" or payload.get("stop_hook_active"):
        return 0                           # already nudged this turn: let it end
    path = payload.get("transcript_path") or ""
    if not os.path.isfile(path):
        return 0

    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("{"):
                    try:
                        rows.append(json.loads(line))
                    except Exception:
                        pass
    except OSError:
        return 0

    msg = last_assistant(rows)
    if msg and should_block(msg):
        sys.stdout.write(json.dumps({"decision": "block", "reason": REASON}))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
