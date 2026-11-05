# Changelog

## 1.0.0 (2026-11-05)
First public version, cut from the author's private kit (engine v6, watcher v9).
- bin/live.sh: three read paths (Krisp live file, accessibility read of the Krisp window, finished transcript) plus the clipboard fallback; modes --tail, --delta, --which, --ax, --new, --find, --use, --live, --me, --clip, --doctor, --status.
- Paths and personal plumbing moved to environment variables with defaults: KRISP_DIR, KRISP_STATE_DIR, KRISP_NOTES_DIR, KRISP_CONFIG, KRISP_MICUSERS, CALL_TEST, ON_CALL_START, ON_CALL_STOP.
- New: KRISP_FILE_ONLY (file mode for tests), KRISP_DELTA_NS (separate --delta offsets), watch.sh --once, and a refusal to run when a state or notes folder resolves inside the Krisp folder.
- Linux file mode: SHA-1 through shasum or sha1sum, GNU date and stat, and no bare "ls -t" from GNU xargs when the Krisp folder is empty. macOS behavior is unchanged.
- Window-layout control is now an optional hook (ON_CALL_START, ON_CALL_STOP) instead of a built-in script.
- "File it" now goes through an adapter (adapters/file-it/): a local queue by default, or a configured task tool.
- Interview help is review-only: /krisp-interview-review and live.sh --finished work on a finished transcript of a mock or practice interview, after the call.
- Consent and recording law section; the watcher's coach can be turned off (KRISP_COACH=0, or a .state/coach-off file).
- tests/test_live.py (26 tests), invented examples and expected outputs, docs/architecture.md.

## Before 1.0.0 (private kit, October 2026)
- Engine v6: accessibility read only when the live file cannot answer, 15 s read cache, clock-shaped timer check.
- Engine v5: reads Krisp's Local Folder live transcript first, with --doctor to report the option.
- Engine v4: accessibility read of the Krisp window, 2 to 3 seconds from speech to buffer in a 23-minute recording.
- Watcher: from a 20 s poll to a 0.5 s loop, file-based recording detection, call detection from the microphone.
