#!/usr/bin/env python3
"""Compare additional smoothing on a real median-filtered camera tensor.

High-pass energy includes scene texture; this is not a ground-truth noise score.
The preview predicts input filtering only, not a new CNN output or HDMI capture.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def gaussian3(rgb):
    h, w, _ = rgb.shape
    padded = np.pad(rgb.astype(np.int32), ((1, 1), (1, 1), (0, 0)), mode='edge')
    return (sum(wy * wx * padded[y:y+h, x:x+w]
                for y, wy in enumerate((1, 2, 1))
                for x, wx in enumerate((1, 2, 1))) + 8) // 16


def highpass_std(rgb):
    # Fixed low-detail region of this diagnostic frame, excluding the logo.
    roi = rgb[150:400, 30:280].astype(np.float64)
    padded = np.pad(roi, ((2, 2), (2, 2), (0, 0)), mode='edge')
    local = sum(padded[y:y+250, x:x+250] for y in range(5) for x in range(5)) / 25
    return (roi-local).std(axis=(0, 1)).tolist()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    raw = args.input.read_bytes()
    data = np.frombuffer(raw, np.uint8).reshape(480, 640, 4)
    if np.any(data[:, :, 3] != 128):
        raise ValueError('invalid INT8 padding channel')
    source = (data[:, :, :3] ^ 128).astype(np.int32)
    once = gaussian3(source)
    twice = gaussian3(once)
    args.output.mkdir(parents=True, exist_ok=True)
    canvas = Image.new('RGB', (1920, 510))
    draw = ImageDraw.Draw(canvas)
    for index, (label, rgb) in enumerate([
        ('Actual median input', source),
        ('Offline: additional Gaussian3', once),
        ('Offline: two additional Gaussian3 stages', twice),
    ]):
        draw.text((640*index+8, 8), label, fill='white')
        canvas.paste(Image.fromarray(rgb.astype(np.uint8)), (640*index, 30))
    canvas.save(args.output/'input-comparison.png')
    Image.fromarray(source.astype(np.uint8)).save(args.output/'captured-input.png')
    report = {
        'scope': 'Actual median input with offline smoothing predictions; no ground-truth noise or HDMI measurement',
        'input_sha256': hashlib.sha256(raw).hexdigest(),
        'roi_xyxy': [30, 150, 280, 400],
        'highpass': 'RGB minus edge-padded 5x5 local mean; standard deviation per channel',
        'actual_median_highpass_std': highpass_std(source),
        'predicted_one_gaussian_highpass_std': highpass_std(once),
        'predicted_two_gaussian_highpass_std': highpass_std(twice),
        'gaussian_kernel': [[1, 2, 1], [2, 4, 2], [1, 2, 1]],
        'divisor': 16,
        'rounding': 'add 8, integer divide by 16 after each 2D stage',
        'border': 'replicate at each stage',
        'limitations': ['Scene texture contributes to high-pass energy.',
                        'The input already passed the median; raw source is unavailable.',
                        'Smoothing also removes real detail; visual acceptance remains necessary.'],
    }
    (args.output/'input-analysis.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))
