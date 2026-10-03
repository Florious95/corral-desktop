#!/usr/bin/env python3
"""Measure terminal ink-to-pane-bottom slack on the isolated packaged-app runway.

The measurement is deliberately made from the exact WindowServer image captured
for the candidate app, while the acceptance driver supplies the matching pane
geometry, backing scale, and terminal rows.  It does not inspect the production
window or use global HID events.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from run import Run  # noqa: E402


# The 948pt window height gives the current 38pt chrome a 910pt stage.  That
# is the user's observed 910 / 16 = 56-row remainder case, so it is kept in
# the default matrix rather than relying only on the stock resize smoke set.
SIZES = ((1400, 860), (1400, 948), (1400, 949), (1000, 720), (800, 700), (640, 600),
         (480, 480), (480, 360), (1400, 860))
INK_THRESHOLD = 60.0
MIN_INK_PIXELS_PER_ROW = 3
EDGE_INSET_PX = 8


def bands(rows):
    result = []
    for row in rows:
        row = int(row)
        if not result or row > result[-1][1] + 1:
            result.append([row, row])
        else:
            result[-1][1] = row
    return result


def pane_container(state, pane):
    # The driver reports pane references without the device prefix while the
    # workspace projection keeps the full SessionID.  They share the tmux
    # socket/pane suffix, which is the stable join key for this evidence.
    projection = next(item for item in state['projection']
                      if item['id'].endswith(pane['ref']))['frame']
    stage_x, stage_y, _, _ = state['stageFrame']
    x, y, width, height = projection
    return [stage_x + x, stage_y + y, width, height]


def measure_pane(image, state, pane):
    scale = float(state['backingScale'])
    image_width, image_height = image.size
    roi_x, roi_y, roi_width, roi_height = map(round, pane['pixelROI'])
    x0 = max(0, roi_x + EDGE_INSET_PX)
    y0 = max(0, roi_y + EDGE_INSET_PX)
    x1 = min(image_width, roi_x + roi_width - EDGE_INSET_PX)
    y1 = min(image_height, roi_y + roi_height - EDGE_INSET_PX)
    pixels = np.asarray(image.convert('RGB'))[y0:y1, x0:x1]
    luma = pixels @ np.array([0.2126, 0.7152, 0.0722])
    row_counts = (luma >= INK_THRESHOLD).sum(axis=1)
    ink_rows = np.flatnonzero(row_counts >= MIN_INK_PIXELS_PER_ROW)
    container_x, container_y, container_width, container_height = pane_container(state, pane)
    window_height = float(state['windowFrame'][3])
    container_bottom_px = round((window_height - container_y) * scale)
    terminal_bottom_px = roi_y + roi_height
    ink_bottom_px = None if not len(ink_rows) else y0 + int(ink_rows[-1]) + 1
    blank_px = None if ink_bottom_px is None else container_bottom_px - ink_bottom_px
    nonempty = [index for index, line in enumerate(pane['rows']) if line.strip()]
    last_nonempty = nonempty[-1] if nonempty else None
    row_count = len(pane['rows'])
    grid_anchored = (last_nonempty is not None and
                     last_nonempty >= max(0, row_count - 2))
    return {
        'ref': pane['ref'],
        'terminalFramePt': pane['frame'],
        'containerFramePt': [container_x, container_y, container_width, container_height],
        'pixelROI': [roi_x, roi_y, roi_width, roi_height],
        'backingScale': scale,
        'imageSizePx': [image_width, image_height],
        'containerBottomPx': container_bottom_px,
        'terminalBottomPx': terminal_bottom_px,
        'terminalToContainerBottomPx': container_bottom_px - terminal_bottom_px,
        'inkThreshold': INK_THRESHOLD,
        'inkBottomPx': ink_bottom_px,
        'blankPx': blank_px,
        'blankPt': None if blank_px is None else blank_px / scale,
        'inkBandsInROI': bands(ink_rows)[-12:],
        'gridRows': row_count,
        'lastNonEmptyRow': last_nonempty,
        'gridAnchored': grid_anchored,
        'cols': pane['cols'],
        'contentsScale': pane['contentsScale'],
    }


def measure_capture(run, state, screenshot, width, height, phase):
    image = Image.open(screenshot)
    entries = []
    for suffix in ('A', 'B'):
        pane = run.view(state, suffix)
        entry = measure_pane(image, state, pane)
        entry.update({'widthPt': width, 'heightPt': height, 'phase': phase,
                      'screenshot': str(screenshot), 'suffix': suffix})
        entries.append(entry)
    return entries


def grid_is_anchored(run, state):
    return all(measure_pane_rows(run.view(state, suffix))
               for suffix in ('A', 'B'))


def measure_pane_rows(pane):
    nonempty = [line for line in pane['rows'] if line.strip()]
    return bool(nonempty) and len(pane['rows']) - 1 <= len(nonempty) + 1


def wait_for_anchored_state(run, state, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if grid_is_anchored(run, state):
            return state
        state = run.command('state')
    return state


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-root', type=Path, required=True)
    parser.add_argument('--no-resize', action='store_true')
    parser.add_argument('--record-only', action='store_true',
                        help='write the evidence but do not fail on the red baseline')
    args = parser.parse_args()
    run = Run(args.legacy_root, case='many-sessions-stress', no_resize=args.no_resize)
    measurements = []
    states = []
    try:
        run.start()
        state = run.sidebar('A')
        stage_width, stage_height = state['stageSize']
        run.command('drop', session=run.session_id('B'), x=stage_width - 10, y=stage_height / 2)
        state = run.visible('B')
        run.settle_geometry(state)
        for width, height in SIZES:
            immediate = run.command('resize-window', width=width, height=height)
            immediate_image = run.capture(f'footer-{width}x{height}-immediate', immediate)
            measurements.extend(measure_capture(run, immediate, immediate_image, width, height, 'immediate'))
            states.append({'widthPt': width, 'heightPt': height, 'phase': 'immediate',
                           'state': immediate})
            if not args.no_resize:
                run.settle_geometry(immediate)
            time.sleep(0.2)
            settled = wait_for_anchored_state(run, run.command('state'))
            settled_image = run.capture(f'footer-{width}x{height}-settled', settled)
            measurements.extend(measure_capture(run, settled, settled_image, width, height, 'settled'))
            states.append({'widthPt': width, 'heightPt': height, 'phase': 'settled',
                           'state': settled})
        red = [item for item in measurements
               if item['gridAnchored'] and item['blankPt'] is not None and item['blankPt'] >= 14.5]
        result = {
            'status': 'RED_BASELINE' if red else 'NO_RED_SAMPLE',
            'candidateHEAD': run.identity['baseHEAD'],
            'candidateTree': run.identity['sourceTree'],
            'appSHA256': run.identity['appSHA256'],
            'measurementToolSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'server': run.identity['server'],
            'runDirectory': str(run.directory),
            'threshold': {'blankPtRedAtOrAbove': 14.5,
                          'inkLuma': INK_THRESHOLD,
                          'minInkPixelsPerRow': MIN_INK_PIXELS_PER_ROW,
                          'edgeInsetPx': EDGE_INSET_PX},
            'measurements': measurements,
            'redSamples': red,
        }
        (run.directory / 'footer-gap-measurements.json').write_text(
            json.dumps(result, ensure_ascii=False, indent=2))
        (run.directory / 'footer-gap-states.json').write_text(
            json.dumps(states, ensure_ascii=False, indent=2))
        anchored = [item['blankPt'] for item in measurements
                    if item['gridAnchored'] and item['blankPt'] is not None]
        print(json.dumps({
            'status': result['status'],
            'runDirectory': str(run.directory),
            'redSampleCount': len(red),
            'maxAnchoredBlankPt': max(anchored, default=None),
            'maxMeasuredBlankPt': max((item['blankPt'] for item in measurements
                                       if item['blankPt'] is not None), default=None),
        }, ensure_ascii=False), flush=True)
        if red and not args.record_only:
            raise SystemExit(1)
    except Exception as error:
        (run.directory / 'footer-gap-failure.txt').write_text(str(error))
        raise
    finally:
        run.cleanup()


if __name__ == '__main__':
    main()
