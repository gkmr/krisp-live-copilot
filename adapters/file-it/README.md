# The "file it" adapter (optional)

Every copilot mode is read-only except one. When you say "file it" after a summary, recap or missed, the copilot lists each ask of you and each decision that needs a follow-up, then files them. Where they go is up to you, through this adapter.

## The interface

The copilot always produces the same item list, one line per item:

    - [ ] <title> | <quote> (<stamp>) from <meeting> on <YYYY-MM-DD> | due <YYYY-MM-DD or none>

- title: the ask in under 80 characters.
- quote and stamp: the words from the transcript and where they are (`Speaker 2 | 00:09:55` or `Live | 21:04:51`).
- due: only when the transcript names a date; otherwise `none`.

`examples/followups-queue.example.md` shows four lines from the invented meeting.

## Where the items go

1. No adapter configured (the default): the items are appended to `notes/followups-<YYYY-MM-DD>.md` in this repo. Nothing leaves the machine.
2. A task tool configured: copy `file-it.example.md` to `file-it.md` at the repo root (it is gitignored) and fill it in. When that tool is available in the session (for example a task manager's MCP connector in Cowork or Claude Code), the copilot reads the target list first, skips titles that already exist, and creates one task per item with the configured tags. It never deletes, completes or edits a task.
3. A script: `queue_to_tasks.py` turns a queue file into JSON task payloads (`title`, `content`, `due`, `tags`), skipping checked items and titles you already have. Pipe the JSON into whatever CLI or API your task tool offers.

```
python3 adapters/file-it/queue_to_tasks.py examples/followups-queue.example.md --tags krisp,meeting
```

The adapter is covered by `tests/test_live.py` (parsing, the `|` inside a stamp, skipping done items and duplicates).
