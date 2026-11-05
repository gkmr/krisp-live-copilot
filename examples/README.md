# Examples (all invented)

Nothing here comes from a real meeting. The people, product and numbers are made up.

```
examples/
  krisp/Krisp Meetings/
    Zoom meeting - October 12, 2026 2-05-31 PM/transcript.md     offline mode beta check-in, 3 speakers
    Chrome meeting - October 14, 2026 9-30-04 AM/transcript.md   pricing page review, 2 speakers
  append.md                      two more turns, appended to the Zoom file to simulate the call going on
  followups-queue.example.md     what "file it" produces for the Zoom meeting (adapter input)
  expected/
    tail-8.txt                   body printed by: live.sh --tail 8
    delta-after-append.txt       body printed by the second live.sh --delta, after append.md is added
    find-10-12.txt               full output of: live.sh --find 10/12
```

The folder layout and file shape follow what live.sh expects from Krisp's Local Folder integration: one folder per meeting named `<app> meeting - <Month D, YYYY h-mm-ss PM>`, and a transcript with three header lines (title, date, duration) followed by `**Speaker N | HH:MM:SS**` label lines, each followed by what was said.

## Try it without Krisp

From the repo root (Linux or macOS):

```
export KRISP_DIR=examples/krisp KRISP_STATE_DIR=$(mktemp -d) KRISP_FILE_ONLY=1
bash bin/live.sh --find 10/12
bash bin/live.sh --use 1
bash bin/live.sh --tail 8
```

`--tail 8` prints one header line, a `----------` line, then the body in `expected/tail-8.txt`. The header looks like this (time and age vary):

```
transcript: Zoom meeting - October 12, 2026 2-05-31 PM | pinned (live.sh --live to unpin) | last write 14:29:31, 1670 bytes | source: files | krisp: file mode (KRISP_FILE_ONLY=1, accessibility read off) | me: unknown, infer from context (the user's own introduction; live.sh --me N records it)
----------
**Speaker 1 | 00:09:47**
I will draft it. Dana, can you review the technical part by Friday?

**Speaker 2 | 00:09:55**
Yes, Friday works.

**Speaker 2 | 00:22:31**
Alex, one question for you. What is the one number you want to hold the beta to? We should agree before we start.
```

That last line is what `/krisp-said` puts first ("asked you: the one number to hold the beta to").

The delta flow, the way the coach and `/krisp-missed` use it, is in `tests/test_live.py` (`TestDelta`): the first `--delta` prints the whole file, the second (after `append.md` is added) prints only `expected/delta-after-append.txt`, and the third prints `(nothing new since last read)`.
