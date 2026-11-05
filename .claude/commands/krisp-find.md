---
description: Krisp meeting: Locate the right Krisp transcript (by date, app, or a name said in the call) and pin it
---
Search words from the user (empty means list the newest): $ARGUMENTS
!`./bin/live.sh --find $ARGUMENTS`

Currently selected:
!`./bin/live.sh --which`

Pick the right one. If exactly one result matches what the user asked for, pin it now by running `./bin/live.sh --use <n>` and confirm in one line (meeting name, date, duration). If several could match, show them as a short numbered list with the date and the first line, and ask which number; the user answers with /krisp-use <n>. If none match, say so and suggest a better search word (a date like 10/12, the app name such as Zoom or Chrome, or a name said in the call). Remind the user in five words that a call in progress is not a file yet: /krisp-live follows it.
