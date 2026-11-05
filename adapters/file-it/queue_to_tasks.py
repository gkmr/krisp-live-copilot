#!/usr/bin/env python3
"""Example "file it" adapter: turn a follow-up queue into task payloads for any task tool.

The krisp skill and the /krisp-file command write follow-ups as one line per item:

    - [ ] <title> | <quote> (<stamp>) from <meeting> on <YYYY-MM-DD> | due <YYYY-MM-DD or none>

This script reads that file and prints a JSON list of tasks, one per open item, in a neutral shape
({"title", "content", "due", "tags"}) that a task manager's API, CLI or MCP create-task tool can take.
Checked items ("- [x]") are skipped, and so is any title already in --existing (one title per line),
so running it twice files nothing twice. It never deletes or completes anything: it only reads.

Usage:
    python3 adapters/file-it/queue_to_tasks.py notes/followups-2026-10-12.md --tags krisp,meeting
    python3 adapters/file-it/queue_to_tasks.py QUEUE --existing titles.txt
Standard library only.
"""
import argparse
import json
import re
import sys

LINE = re.compile(r'^\s*- \[( |x|X)\] (.+)$')
DUE = re.compile(r'^due (\d{4}-\d{2}-\d{2}|none)$')


def parse_line(line):
    """Return a dict for one queue line, or None when the line is not a queue item."""
    m = LINE.match(line.rstrip('\n'))
    if not m:
        return None
    done = m.group(1).lower() == 'x'
    body = m.group(2)
    if ' | ' not in body:
        return None
    title, rest = body.split(' | ', 1)
    # the quote's stamp can itself hold " | " (Speaker 1 | 00:09:47), so the due field is taken from the right
    if ' | ' in rest:
        content, due_field = rest.rsplit(' | ', 1)
    else:
        content, due_field = rest, 'due none'
    d = DUE.match(due_field.strip())
    if not d:
        content, due = rest, None
    else:
        due = None if d.group(1) == 'none' else d.group(1)
    return {'title': title.strip(), 'content': content.strip(), 'due': due, 'done': done}


def build(queue_text, tags=(), existing=()):
    seen = {t.strip().lower() for t in existing if t.strip()}
    out = []
    for line in queue_text.splitlines():
        item = parse_line(line)
        if not item or item['done']:
            continue
        key = item['title'].lower()
        if key in seen:
            continue
        seen.add(key)
        out.append({'title': item['title'], 'content': item['content'], 'due': item['due'], 'tags': list(tags)})
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('queue', help='the follow-up queue file (markdown)')
    ap.add_argument('--tags', default='krisp,meeting', help='comma-separated tags for every task')
    ap.add_argument('--existing', help='file with titles that already exist, one per line')
    a = ap.parse_args(argv)
    text = open(a.queue, encoding='utf-8').read()
    existing = open(a.existing, encoding='utf-8').read().splitlines() if a.existing else []
    tags = [t.strip() for t in a.tags.split(',') if t.strip()]
    json.dump(build(text, tags, existing), sys.stdout, indent=2)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
