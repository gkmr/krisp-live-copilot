---
description: Krisp meeting: Pull the full text of the current transcript into the conversation (for questions about a past meeting)
---
Current transcript:
!`./bin/live.sh --tail 100000`

Say in one line which meeting this is, how long, how many speakers and which one is the user if known. Then wait for the user's question; answer only from this text. If the user gave words after the command, treat them as the question: $ARGUMENTS
