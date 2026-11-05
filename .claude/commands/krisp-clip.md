---
description: Krisp meeting: Clipboard fallback for the live transcript (tap Copy on Krisp's Transcript tab first); not needed while the live read works
---
!`./bin/live.sh --clip`
!`./bin/live.sh --tail 25`

Confirm in one line which transcript is current (the live call read from the app, the clipboard copy, or a file) and how many lines it has. If the header says the live read works, tell the user the Copy step is no longer needed. If the clipboard did not look like a Krisp transcript and the live read is denied, say exactly: open Krisp, Transcript tab, tap Copy, then run /krisp-clip again. Then answer $ARGUMENTS if given, under 80 words.
Rules and voice: @CLAUDE.md
