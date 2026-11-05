#!/usr/bin/env python3
"""Tests for bin/live.sh in file mode, plus the watcher's classifier and the file-it adapter.

Runs on Linux or macOS with python3 and bash; no Krisp app, no accessibility, no network.
Every test copies examples/krisp into a temporary folder, so the repo's examples never change.

    python3 tests/test_live.py          (or: python3 -m unittest discover -s tests -v)
"""
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True  # importing the adapter must not leave __pycache__ in the repo
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE = os.path.join(ROOT, 'bin', 'live.sh')
WATCH = os.path.join(ROOT, 'bin', 'watch.sh')
EX = os.path.join(ROOT, 'examples')
EXPECTED = os.path.join(EX, 'expected')
MEETINGS = 'Krisp Meetings'
ZOOM = 'Zoom meeting - October 12, 2026 2-05-31 PM'
CHROME = 'Chrome meeting - October 14, 2026 9-30-04 AM'
SEP = '----------\n'


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def snapshot(folder):
    """Every file under folder with its size and mtime, to prove a run wrote nothing there."""
    out = {}
    for dp, _, fns in os.walk(folder):
        for fn in fns:
            p = os.path.join(dp, fn)
            st = os.stat(p)
            out[os.path.relpath(p, folder)] = (st.st_size, st.st_mtime_ns)
    return out


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='klc-test-')
        self.krisp = os.path.join(self.tmp, 'krisp')
        shutil.copytree(os.path.join(EX, 'krisp'), self.krisp)
        self.state = os.path.join(self.tmp, 'state')
        self.zoom = os.path.join(self.krisp, MEETINGS, ZOOM, 'transcript.md')
        self.chrome = os.path.join(self.krisp, MEETINGS, CHROME, 'transcript.md')
        # a fresh copy counts as written now; tests that need an older file set its age
        self.age(self.zoom, 0)
        self.age(self.chrome, 0)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def age(self, path, seconds):
        t = time.time() - seconds
        os.utime(path, (t, t))

    def only(self, *keep):
        """Keep only the named meeting folders in the temp Krisp folder."""
        for name in (ZOOM, CHROME):
            if name not in keep:
                shutil.rmtree(os.path.join(self.krisp, MEETINGS, name))

    def run_live(self, *args, env_extra=None, check=True):
        env = dict(os.environ)
        env.update({'KRISP_DIR': self.krisp, 'KRISP_STATE_DIR': self.state, 'KRISP_FILE_ONLY': '1',
                    'KRISP_CONFIG': os.path.join(self.tmp, 'no-config.json')})
        env.pop('KRISP_DELTA_NS', None)
        env.update(env_extra or {})
        p = subprocess.run(['bash', LIVE] + list(args), cwd=ROOT, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
        if check:
            self.assertEqual(p.returncode, 0, 'live.sh %s failed: %s' % (' '.join(args), p.stderr))
        return p

    def split(self, out):
        """Header line and body of a transcript print."""
        header, sep, body = out.partition('\n' + SEP)
        self.assertTrue(sep, 'no separator line in output:\n' + out)
        return header, body


class TestTail(Base):
    def test_tail_n_matches_example_and_file(self):
        self.only(ZOOM)
        header, body = self.split(self.run_live('--tail', '8').stdout)
        self.assertTrue(header.startswith('transcript: ' + ZOOM + ' | LIVE FILE'), header)
        self.assertIn('source: files', header)
        self.assertEqual(body, read(os.path.join(EXPECTED, 'tail-8.txt')))
        lines = read(self.zoom).splitlines(keepends=True)
        self.assertEqual(body, ''.join(lines[-8:]))

    def test_default_tail_is_40_lines(self):
        self.only(ZOOM)
        _, body = self.split(self.run_live().stdout)
        lines = read(self.zoom).splitlines(keepends=True)
        self.assertEqual(body, ''.join(lines[-40:]))

    def test_me_label(self):
        self.only(ZOOM)
        self.assertIn('me: unknown', self.run_live('--which').stdout)
        self.assertIn('you = Speaker 1', self.run_live('--me', '1').stdout)
        self.assertIn('me: Speaker 1', self.run_live('--which').stdout)


class TestDelta(Base):
    def test_delta_returns_only_new_lines(self):
        self.only(ZOOM)
        _, first = self.split(self.run_live('--delta').stdout)
        self.assertEqual(first, read(self.zoom), 'first --delta prints the whole transcript')
        with open(self.zoom, 'a', encoding='utf-8') as f:
            f.write(read(os.path.join(EX, 'append.md')))
        _, second = self.split(self.run_live('--delta').stdout)
        self.assertEqual(second, read(os.path.join(EXPECTED, 'delta-after-append.txt')))
        _, third = self.split(self.run_live('--delta').stdout)
        self.assertEqual(third, '(nothing new since last read)\n')

    def test_delta_resets_when_the_file_shrinks(self):
        self.only(ZOOM)
        self.run_live('--delta')
        short = 'Offline mode beta check-in\nOctober 12, 2026 2:05 PM\n24 min\n'
        with open(self.zoom, 'w', encoding='utf-8') as f:
            f.write(short)
        _, body = self.split(self.run_live('--delta').stdout)
        self.assertEqual(body, short)

    def test_delta_namespaces_are_independent(self):
        self.only(ZOOM)
        self.run_live('--delta')
        _, shared = self.split(self.run_live('--delta').stdout)
        self.assertEqual(shared, '(nothing new since last read)\n')
        _, coach = self.split(self.run_live('--delta', env_extra={'KRISP_DELTA_NS': 'coach'}).stdout)
        self.assertEqual(coach, read(self.zoom), 'a new namespace starts at offset 0')


class TestFind(Base):
    def setUp(self):
        super().setUp()
        self.age(self.zoom, 3 * 86400)
        self.age(self.chrome, 1 * 86400)

    def test_find_by_date_word(self):
        expected = read(os.path.join(EXPECTED, 'find-10-12.txt'))
        for words in (['10/12'], ['Oct', '12'], ['october', '12'], ['10-12']):
            self.assertEqual(self.run_live('--find', *words).stdout, expected, words)
        out = self.run_live('--find', 'Oct', '14').stdout
        self.assertIn('1. ' + CHROME + ' | 12 min |', out)
        self.assertNotIn(ZOOM, out)

    def test_find_by_word_said(self):
        out = self.run_live('--find', 'offline').stdout
        self.assertIn('1. ' + ZOOM + ' | 24 min |', out)
        self.assertIn('match: said in the call', out)
        self.assertNotIn(CHROME, out)

    def test_find_empty_lists_newest_first(self):
        out = self.run_live('--find').stdout
        hits = re.findall(r'^(\d+)\. (.+?) \| ', out, re.M)
        self.assertEqual(hits, [('1', CHROME), ('2', ZOOM)])

    def test_find_no_match_and_bad_month(self):
        self.assertIn('no transcript matches "zebra"', self.run_live('--find', 'zebra').stdout)
        self.assertIn('no transcript matches "13/40"', self.run_live('--find', '13/40').stdout)


class TestPin(Base):
    def test_pin_beats_live_file_until_unpinned(self):
        self.age(self.zoom, 3 * 86400)
        self.age(self.chrome, 2 * 86400)
        self.run_live('--find', '10/12')
        self.assertIn('pinned: ' + ZOOM, self.run_live('--use', '1').stdout)
        # the other meeting becomes a live file (written now): the pin still wins
        with open(self.chrome, 'a', encoding='utf-8') as f:
            f.write('\n**Speaker 1 | 00:12:01**\nOne more thing.\n')
        out = self.run_live('--which').stdout
        self.assertIn('| pinned (', out)
        self.assertIn('path: ' + self.zoom, out)
        self.assertIn('unpinned', self.run_live('--live').stdout)
        out = self.run_live('--which').stdout
        self.assertIn('LIVE FILE', out)
        self.assertIn('path: ' + self.chrome, out)

    def test_use_without_find_fails_cleanly(self):
        p = self.run_live('--use', '1', check=False)
        self.assertEqual(p.returncode, 1)
        self.assertIn('nothing to pin', p.stdout)


class TestSelection(Base):
    def test_age_decides_live_recent_or_not_live(self):
        self.only(ZOOM)
        self.assertIn('| LIVE FILE, Krisp is writing it', self.run_live('--which').stdout)
        self.age(self.zoom, 3600)
        self.assertIn('| newest file, written in the last 4 hours', self.run_live('--which').stdout)
        self.age(self.zoom, 2 * 86400)
        self.assertIn('| newest on disk, NOT live', self.run_live('--which').stdout)

    def test_open_live_transcript_counts_as_live_during_silence(self):
        self.only(ZOOM)
        folder = os.path.dirname(self.zoom)
        live = os.path.join(folder, 'live_transcript.md')
        os.rename(self.zoom, live)
        self.age(live, 600)  # quiet for 10 minutes, still no transcript.md: the call is open
        self.assertIn('| LIVE FILE, still open for this call', self.run_live('--which').stdout)

    def test_empty_folder_says_so(self):
        self.only()
        out = self.run_live('--tail', '5').stdout
        self.assertTrue(out.startswith('no transcript found under'), out)


class TestSafety(Base):
    def test_never_writes_into_the_krisp_folder(self):
        before = snapshot(self.krisp)
        for args in (['--tail', '5'], ['--delta'], ['--delta'], ['--which'], ['--find', '10/12'], ['--use', '1'],
                     ['--live'], ['--me', '2'], ['--doctor'], ['--status'], ['--new'], ['--ax'], ['--clip']):
            self.run_live(*args, check=False)
        self.assertEqual(snapshot(self.krisp), before)

    def test_refuses_a_state_folder_inside_the_krisp_folder(self):
        before = snapshot(self.krisp)
        inside = os.path.join(self.krisp, 'state')
        p = self.run_live('--tail', '5', env_extra={'KRISP_STATE_DIR': inside}, check=False)
        self.assertEqual(p.returncode, 2)
        self.assertIn('refusing to run', p.stderr)
        self.assertFalse(os.path.exists(inside))
        self.assertEqual(snapshot(self.krisp), before)


class TestScripts(Base):
    def test_shell_syntax(self):
        for name in ('live.sh', 'watch.sh', 'coach.sh'):
            p = subprocess.run(['bash', '-n', os.path.join(ROOT, 'bin', name)], stderr=subprocess.PIPE, text=True)
            self.assertEqual(p.returncode, 0, name + ': ' + p.stderr)

    def test_watch_once_classifies_without_side_effects(self):
        env = dict(os.environ, KRISP_DIR=self.krisp, KRISP_STATE_DIR=self.state, KRISP_FILE_ONLY='1')
        before = snapshot(self.krisp)
        p = subprocess.run(['bash', WATCH, '--once'], cwd=ROOT, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertRegex(p.stdout, r'^state (nokrisp|recording|call|idle|denied) \| ')
        self.assertFalse(os.path.exists(os.path.join(self.state, 'coach.pid')))
        self.assertEqual(snapshot(self.krisp), before)


class TestFinished(Base):
    """--finished feeds after-call review (a mock interview) and must refuse anything live or still being written."""

    def test_refuses_a_transcript_written_just_now(self):
        self.only(ZOOM)
        out = self.run_live('--finished').stdout
        self.assertTrue(out.startswith('not a finished transcript'), out)
        self.assertNotIn('Alex, one question for you', out)

    def test_prints_a_finished_transcript_after_the_call(self):
        self.only(ZOOM)
        self.age(self.zoom, 3600)
        header, body = self.split(self.run_live('--finished').stdout)
        self.assertIn('newest file, written in the last 4 hours', header)
        self.assertEqual(body, read(self.zoom))

    def test_refuses_an_open_live_transcript(self):
        self.only(ZOOM)
        live = os.path.join(os.path.dirname(self.zoom), 'live_transcript.md')
        os.rename(self.zoom, live)
        self.age(live, 600)
        out = self.run_live('--finished').stdout
        self.assertTrue(out.startswith('not a finished transcript'), out)
        self.assertNotIn('Alex, one question for you', out)

    def test_a_pin_must_be_finished_too(self):
        self.age(self.zoom, 3 * 86400)
        self.run_live('--find', '10/12')
        self.run_live('--use', '1')
        _, body = self.split(self.run_live('--finished').stdout)
        self.assertEqual(body, read(self.zoom))
        self.run_live('--find', 'Oct', '14')  # the Chrome meeting was written just now
        self.run_live('--use', '1')
        self.assertTrue(self.run_live('--finished').stdout.startswith('not a finished transcript'))


class TestCommands(unittest.TestCase):
    def test_interview_help_is_review_only(self):
        cmds = os.path.join(ROOT, '.claude', 'commands')
        names = sorted(os.listdir(cmds))
        self.assertNotIn('krisp-interview.md', names)
        self.assertIn('krisp-interview-review.md', names)
        self.assertIn('./bin/live.sh --finished', read(os.path.join(cmds, 'krisp-interview-review.md')))
        for n in names:
            if n != 'krisp-interview-review.md':
                self.assertNotIn('interview', read(os.path.join(cmds, n)).lower(), n)
        self.assertIn('interview-review `--finished`', read(os.path.join(ROOT, 'skills', 'krisp', 'SKILL.md')))


class TestFileItAdapter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = os.path.join(ROOT, 'adapters', 'file-it', 'queue_to_tasks.py')
        spec = importlib.util.spec_from_file_location('queue_to_tasks', path)
        cls.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.mod)

    def test_parses_queue_and_skips_done_and_existing(self):
        text = read(os.path.join(EX, 'followups-queue.example.md'))
        tasks = self.mod.build(text, ['krisp', 'meeting'], existing=['ship the beta with a 20 MB attachment limit and a clear message'])
        self.assertEqual([t['title'] for t in tasks],
                         ['Draft the offline mode help article for support', 'Get the technical review of the help article'])
        self.assertIsNone(tasks[0]['due'])
        self.assertEqual(tasks[1]['due'], '2026-10-16')
        self.assertIn('(Speaker 1 | 00:09:47)', tasks[1]['content'], 'a | inside the stamp stays in the content')
        self.assertEqual(tasks[1]['tags'], ['krisp', 'meeting'])

    def test_duplicate_titles_file_once(self):
        line = '- [ ] Send the beta criteria | Can you send it? (Speaker 2 | 00:24:10) from a call on 2026-10-12 | due none\n'
        self.assertEqual(len(self.mod.build(line + line)), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
