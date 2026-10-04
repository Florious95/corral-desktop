#!/usr/bin/env python3
"""Real offline Pi selection over private PTY, with exact-window pixel sampling.
No system input. ACK/ANSI timing and WindowServer timing are separate receipts.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time
import traceback
from PIL import Image, ImageChops
from run import Run, wait_for


class PixelSampler:
    def __init__(self, directory, window, roi):
        self.path = directory / 'selection-sampling.png'
        self.window, self.roi = window, roi
        self.stop_event = threading.Event()
        self.samples = []
        self.failure = None
        self.thread = threading.Thread(target=self.collect, daemon=True)

    def collect(self):
        try:
            while not self.stop_event.is_set():
                started = time.time()
                subprocess.run(['screencapture', '-l', str(self.window), '-o', '-x', str(self.path)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                with Image.open(self.path) as image:
                    digest = hashlib.sha256(image.convert('RGB').crop(self.roi).tobytes()).hexdigest()
                self.samples.append({'started': started, 'completed': time.time(), 'sha256': digest})
                self.stop_event.wait(.025)
        except Exception as error:
            self.failure = str(error)

    def start(self):
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=10)
        assert not self.thread.is_alive(), 'pixel sampler did not stop'
        assert self.failure is None, self.failure


def verify(run, scrollbar=False):
    run.command('sidebar', session=run.session_id('P'), count=2)
    def ready():
        state = run.command('state')
        pane = run.view(state, 'P')
        return state if pane['mouseMode'] != 'off' and pane['focused'] else None
    state = wait_for(ready, 30)
    # Reveal transcript history; avoid the input editor, link buttons and the scrollbar.
    run.command('scroll', ref=run.refs['P'], delta=40, precise=True)
    time.sleep(3)
    state = run.command('state')
    pane = run.view(state, 'P')
    before_ranges = pane['inverseRanges']
    x, y, w, h = pane['pixelROI']
    roi = tuple(map(round, (x + w * .04, y + h * .18, x + w * .85, y + h * .72)))
    if scrollbar:
        run.command('scroll', ref=run.refs['P'], delta=40, precise=True) # reveal auto-hiding Pi scrollbar
    before_image = run.capture('selection-before', state)
    sampler = PixelSampler(run.directory, state['windowID'], roi)
    wire_before = len(run.wire())
    sampler.start()
    try:
        gesture = dict(column=-1, cycles=5, path=[1, .03, 1, .78]) if scrollbar else dict(cycles=5.5, path=[.10, .25, .65, .65])
        drag = run.command('terminal-drag', ref=run.refs['P'], seconds=10, rate=120, **gesture)['lastDrag']
        released = drag['releasedWall']
        # Continue sampling throughout the potential tail, not just a screenshot after waiting.
        time.sleep(3)
    finally:
        sampler.stop()
    state = run.command('state')
    pane = run.view(state, 'P')
    after_ranges = pane['inverseRanges']
    assert pane['nativeSelection'] == '', 'This must exercise Pi selection, not native Shift selection'
    selected_rows = []
    if not scrollbar:
        assert len(after_ranges) >= 3 and after_ranges != before_ranges, ('no multiline Pi selection', after_ranges)
        anchor_row = int(len(pane['rows']) * .25)
        focus_row = int(len(pane['rows']) * .65)
        selected_rows = [row for row, left, right in after_ranges if anchor_row <= row <= focus_row]
        assert selected_rows and min(selected_rows) == anchor_row and max(selected_rows) == focus_row, (anchor_row, focus_row, after_ranges)
    after_image = run.capture('selection-after', state)
    with Image.open(before_image) as a, Image.open(after_image) as b:
        assert ImageChops.difference(a.convert('RGB').crop(roi), b.convert('RGB').crop(roi)).getbbox(), 'selection has no visible pixels'
        final_hash = hashlib.sha256(b.convert('RGB').crop(roi).tobytes()).hexdigest()
    samples = sampler.samples
    assert len(samples) > 20 and len({s['sha256'] for s in samples}) > 10, 'pixels must actually follow the drag'
    assert samples[-1]['sha256'] == final_hash, 'final frame differs after sampling stopped'
    stable_start = len(samples) - 1
    while stable_start > 0 and samples[stable_start-1]['sha256'] == final_hash:
        stable_start -= 1
    stable_sample = next((s for s in samples[stable_start:] if s['started'] >= released), None)
    assert stable_sample, 'no post-release settled pixel sample'
    pixel_tail_upper_ms = max(0, (stable_sample['completed'] - released) * 1000)
    events = run.wire()[wire_before:]
    acks = [e['at'] for e in events if e.get('type') == 'input_ack']
    assert acks
    ack_tail_ms = max(0, acks[-1] - released * 1000)
    summary = {'mode': 'scrollbar' if scrollbar else 'selection',
               'scope': 'real offline Pi / private PTY / app-local NSEvent / exact WindowServer window',
               'systemHID': 'NOT-RUN', 'events': drag['events'],
               'dragSeconds': drag['releasedWall'] - drag['startedWall'],
               'ackTailMilliseconds': ack_tail_ms, 'pixelTailUpperBoundMilliseconds': pixel_tail_upper_ms,
               'pixelSamples': len(samples), 'uniqueFrames': len({s['sha256'] for s in samples}),
               'selectedRows': selected_rows, 'inverseRanges': after_ranges,
               'samplerMaximumIntervalMilliseconds': max((b['completed']-a['completed'])*1000 for a,b in zip(samples,samples[1:]))}
    (run.directory / 'selection-pixels.json').write_text(json.dumps(samples, indent=2))
    (run.directory / 'pi-pointer-pixels.json').write_text(json.dumps(summary, indent=2))
    print('PI_POINTER_PIXELS', json.dumps(summary), flush=True)
    assert ack_tail_ms <= 500, 'obsolete input kept reaching Pi after release'
    assert pixel_tail_upper_ms <= 500, 'selection pixels kept moving after release'
    if not scrollbar:
        # A new press must reset deduplication: start another body selection.
        run.command('terminal-drag', ref=run.refs['P'], seconds=.4, rate=60, cycles=0, path=[.15, .35, .4, .45])
        final = run.view(run.command('state'), 'P')['inverseRanges']
        assert final != after_ranges, 'a subsequent selection gesture did not update the highlight'
    run.write_case_summary()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-root', type=Path, required=True)
    parser.add_argument('--pi-session', type=Path, required=True)
    parser.add_argument('--mode', choices=['selection', 'scrollbar'], default='selection')
    args = parser.parse_args()
    run = Run(args.legacy_root, case='pi-scrollbar-drag', pi_session=args.pi_session)
    run.case = 'pi-' + args.mode + '-pixels'
    try:
        run.start()
        verify(run, scrollbar=args.mode == 'scrollbar')
    except Exception:
        (run.directory / 'failure.txt').write_text(traceback.format_exc())
        (run.directory / 'summary.json').write_text(json.dumps({'status': 'FAIL', 'identity': getattr(run, 'identity', {})}, indent=2))
        raise
    finally:
        run.cleanup()
