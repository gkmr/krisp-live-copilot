---
description: Krisp meeting: Summarize the call thus far in extreme detail
---
Full transcript so far:
!`./bin/live.sh --tail 100000`

Write the detailed running summary the user asked for ("summarize thus far but in extreme detail"). This is the one command that is allowed to be long. Structure, with timestamps from the transcript wherever they exist:
1. Who is on the call and how you know (speaker numbers mapped to names where the transcript gives them; the user's speaker number; on live lines, who you take each remark to be from and why).
2. Timeline: every topic in order with its timestamp range, what each side said, verbatim quotes for anything that sounded like a commitment, a number, a date, a name, a title, a price, a headcount or a deadline.
3. Decisions made, each with who said it and when.
4. Asks of the user and promises the user made, each with any date.
5. Facts and numbers stated by the other side, as a list, exact.
6. Open questions and anything left unresolved.
7. Signals: tone shifts, hesitations, enthusiasm, pushback, with the quote that shows it.
8. Suggested next step for the user in two lines.
Everything from the transcript only; mark anything inferred as "inferred". Write it to ./notes/summary-<YYYY-MM-DD>-<HHMM>.md as well as printing it.
