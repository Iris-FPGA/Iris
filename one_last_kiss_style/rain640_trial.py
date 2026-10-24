#!/usr/bin/env python3
"""Isolated Rain teacher -> aligned-patch student -> 640x480 INT8 trial.

Reuses the existing c448_lowdec_skip_r0 student, not Rain's full architecture.
Training and export are explicit subcommands; nothing updates board firmware.
"""
import argparse
import hashlib
import json
import random
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
CANDIDATE = 'c448_lowdec_skip_r0'
SEED = 20261020


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2)+'\n')


def frame(path):
    with Image.open(path) as source:
        im = source.convert('RGB')
    w, h = im.size
    if w * 3 > h * 4:
        nw = h * 4 // 3
        im = im.crop(((w-nw)//2, 0, (w+nw)//2, h))
    else:
        nh = w * 3 // 4
        im = im.crop((0, (h-nh)//2, w, (h+nh)//2))
    return np.asarray(im.resize((640, 480), Image.Resampling.BILINEAR))


def runtime(path):
    from tflite_runtime.interpreter import Interpreter, OpResolverType
    rt = Interpreter(model_path=str(path), num_threads=2,
                     experimental_op_resolver_type=OpResolverType.BUILTIN_REF)
    rt.allocate_tensors()
    return rt


def predict(rt, rgb):
    inp = rt.get_input_details()[0]
    scale, zero = inp['quantization']
    q = np.clip(np.rint(rgb.astype(np.float32)/scale)+zero, -128, 127).astype(np.int8)
    rt.set_tensor(inp['index'], q[None])
    rt.invoke()
    return rt.get_tensor(rt.get_output_details()[0]['index'])[0]


def dequantize(q, quant):
    scale, zero = quant
    return np.clip((q.astype(np.float32)-zero)*scale, 0, 255)


def provenance(out):
    manifest = json.loads((out/'data-manifest.json').read_text())
    teacher = out/'teacher/rain_princess_640x480_int8.tflite'
    if digest(teacher) != manifest['teacher_sha256']:
        raise RuntimeError('teacher differs from cached targets')
    if digest(Path(__file__)) != manifest['trial_source_sha256']:
        raise RuntimeError('trial script differs from cached provenance')
    if digest(ROOT/'distill.py') != manifest['student_source_sha256']:
        raise RuntimeError('student implementation differs from cached provenance')
    return manifest


def prepare(args):
    from distill import dataset
    out = args.output
    cache = out/'cache'
    cache.mkdir(parents=True, exist_ok=True)
    splits = dataset()
    teacher = out/'teacher/rain_princess_640x480_int8.tflite'
    manifest = {'seed': SEED, 'teacher_sha256': digest(teacher),
                'original_model_sha256': digest(ROOT/'models/rain-princess-cropped_style_int8.tflite'),
                'trial_source_sha256': digest(Path(__file__)),
                'student_source_sha256': digest(ROOT/'distill.py'),
                'dataset_archive_sha256': digest(ROOT/'data/coco128.zip'),
                'teacher_runtime': 'TFLite BUILTIN_REF; unchanged INT8 parameters',
                'frame_shape': [480, 640, 3],
                'splits': {key: [{'file': p.name, 'sha256': digest(p)} for p in paths]
                           for key, paths in splits.items()}}
    rt = runtime(teacher)
    manifest['teacher_output_quantization'] = list(rt.get_output_details()[0]['quantization'])
    manifest_path = out/'data-manifest.json'
    if manifest_path.exists() and json.loads(manifest_path.read_text()) != manifest:
        raise RuntimeError('existing target provenance differs; use another trial directory')
    save_json(manifest_path, manifest)
    for split, paths in splits.items():
        for i, path in enumerate(paths):
            stem = cache/path.stem
            image_path = stem.with_suffix('.input.npy')
            if not image_path.exists():
                np.save(image_path, frame(path))
            if split != 'calibration':
                target_path = stem.with_suffix('.target.npy')
                if not target_path.exists():
                    np.save(target_path, predict(rt, np.load(image_path)))
            if i % 10 == 0:
                print(json.dumps({'stage': 'teacher_targets', 'split': split, 'image': i}), flush=True)
    save_json(out/'prepared.json', {'manifest_sha256': digest(manifest_path),
                                  'train': 80, 'calibration': 16, 'validation': 32})


def train(args):
    import torch
    from torch.nn import functional as F
    from distill import Student, CANDIDATES
    out = args.output
    manifest = provenance(out)
    prepared = json.loads((out/'prepared.json').read_text())
    if prepared['manifest_sha256'] != digest(out/'data-manifest.json'):
        raise RuntimeError('preparation manifest differs')
    patch = args.patch
    if patch % 4 or not 64 <= patch <= 480 or args.steps <= 0 or args.batch <= 0:
        raise ValueError('invalid training dimensions or step count')
    checkpoint = out/'student.pt'
    if checkpoint.exists():
        raise ValueError('checkpoint already exists; use another trial directory')
    torch.set_num_threads(2)
    torch.manual_seed(SEED)
    rng = random.Random(SEED)
    model = Student(*CANDIDATES[CANDIDATE]).train()
    optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
    quant = manifest['teacher_output_quantization']
    pairs = []
    for item in manifest['splits']['train']:
        stem = out/'cache'/Path(item['file']).stem
        pairs.append((np.load(stem.with_suffix('.input.npy'), mmap_mode='r'),
                      np.load(stem.with_suffix('.target.npy'), mmap_mode='r')))
    begin = time.monotonic()
    with (out/'training.jsonl').open('x') as log:
        for step in range(args.steps):
            xs, ys = [], []
            for _ in range(args.batch):
                x, y = rng.choice(pairs)
                top = rng.randrange(0, 480-patch+1, 4)
                left = rng.randrange(0, 640-patch+1, 4)
                x = x[top:top+patch, left:left+patch]
                y = dequantize(y[top:top+patch, left:left+patch], quant)
                if rng.random() < .5:
                    x, y = x[:, ::-1], y[:, ::-1]
                xs.append(x.transpose(2, 0, 1).copy())
                ys.append(y.transpose(2, 0, 1).copy())
            x = torch.from_numpy(np.stack(xs).astype(np.float32))
            y = torch.from_numpy(np.stack(ys))/255
            for group in optimizer.param_groups:
                group['lr'] = 1e-3 if step < args.steps*.7 else 2e-4
            optimizer.zero_grad(set_to_none=True)
            p = model(x)/255
            # Exclude synthetic crop boundaries; teacher saw the whole frame.
            p, y = p[:, :, 16:-16, 16:-16], y[:, :, 16:-16, 16:-16]
            loss = F.l1_loss(p, y)
            for axis in (-1, -2):
                loss = loss + .25*F.l1_loss(torch.diff(p, dim=axis), torch.diff(y, dim=axis))
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1)
            optimizer.step()
            if step % 50 == 0 or step+1 == args.steps:
                row = {'step': step+1, 'steps': args.steps, 'patch': patch,
                       'loss': float(loss.detach()),
                       'elapsed_seconds': round(time.monotonic()-begin, 3)}
                log.write(json.dumps(row)+'\n'); log.flush()
                print(json.dumps(row), flush=True)
    torch.save({'state_dict': model.state_dict(), 'candidate': CANDIDATE,
                'steps': args.steps, 'patch': patch, 'batch': args.batch,
                'teacher_sha256': manifest['teacher_sha256'],
                'manifest_sha256': digest(out/'data-manifest.json'),
                'trial_source_sha256': manifest['trial_source_sha256'],
                'training_seconds': time.monotonic()-begin}, checkpoint)


def export(args):
    import torch
    import tensorflow as tf
    from distill import Student, CANDIDATES
    from export import Folded
    out = args.output
    manifest = provenance(out)
    ckpt = torch.load(out/'student.pt', map_location='cpu', weights_only=True)
    if ckpt['manifest_sha256'] != digest(out/'data-manifest.json'):
        raise RuntimeError('checkpoint provenance differs')
    model = Student(*CANDIDATES[CANDIDATE]).eval()
    model.load_state_dict(ckpt['state_dict'])
    folded = Folded(model)
    first = out/'cache'/Path(manifest['splits']['calibration'][0]['file']).stem
    x = np.load(first.with_suffix('.input.npy')).astype(np.float32)[None]
    with torch.no_grad():
        raw = model(torch.from_numpy(x.transpose(0, 3, 1, 2))).numpy().transpose(0, 2, 3, 1)
    folding_error = float(abs(raw-folded(tf.constant(x)).numpy()).max())
    if folding_error > .02:
        raise RuntimeError(f'BN folding mismatch: {folding_error}')
    signature = tf.TensorSpec([1, 480, 640, 3], tf.float32, name='pixels')
    converter = tf.lite.TFLiteConverter.from_concrete_functions(
        [folded.__call__.get_concrete_function(signature)], folded)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]

    def calibration():
        for item in manifest['splits']['calibration']:
            stem = out/'cache'/Path(item['file']).stem
            yield [np.load(stem.with_suffix('.input.npy')).astype(np.float32)[None]]
        yield [np.zeros((1, 480, 640, 3), np.float32)]
        yield [np.full((1, 480, 640, 3), 255, np.float32)]

    converter.representative_dataset = calibration
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8
    path = out/'rain_student_640x480_int8.tflite'
    if path.exists():
        raise ValueError('export already exists')
    path.write_bytes(converter.convert())
    rt = runtime(path)
    inp, output = rt.get_input_details()[0], rt.get_output_details()[0]
    if inp['shape'].tolist() != [1, 480, 640, 3] or output['shape'].tolist() != [1, 480, 640, 3]:
        raise RuntimeError('export shape mismatch')
    if inp['quantization'] != (1., -128):
        raise RuntimeError('unexpected RGB transport quantization')
    save_json(out/'export.json', {'model_sha256': digest(path), 'model_bytes': path.stat().st_size,
                                'checkpoint_sha256': digest(out/'student.pt'),
                                'candidate': CANDIDATE, 'bn_fold_max_abs': folding_error,
                                'input_shape': inp['shape'].tolist(),
                                'output_shape': output['shape'].tolist(),
                                'input_quantization': inp['quantization'],
                                'output_quantization': output['quantization'],
                                'hardware_proven': False})


def evaluate(args):
    import torch
    from distill import Student, CANDIDATES
    from export import metrics
    out = args.output
    manifest = provenance(out)
    ckpt = torch.load(out/'student.pt', map_location='cpu', weights_only=True)
    model = Student(*CANDIDATES[CANDIDATE]).eval()
    model.load_state_dict(ckpt['state_dict'])
    torch.set_num_threads(2)
    rt = runtime(out/'rain_student_640x480_int8.tflite')
    oq = rt.get_output_details()[0]['quantization']
    native = runtime(ROOT/'models/rain-princess-cropped_style_int8.tflite')
    nq = native.get_output_details()[0]['quantization']
    images = out/'comparison'
    images.mkdir(exist_ok=True)
    rows = []
    for index, item in enumerate(manifest['splits']['validation']):
        stem = out/'cache'/Path(item['file']).stem
        x = np.load(stem.with_suffix('.input.npy'))
        target = dequantize(np.load(stem.with_suffix('.target.npy')), manifest['teacher_output_quantization'])
        start = time.monotonic()
        actual = dequantize(predict(rt, x), oq)
        elapsed = time.monotonic()-start
        with torch.no_grad():
            floating = model(torch.from_numpy(x.transpose(2, 0, 1).copy()).float()[None]).numpy().transpose(0, 2, 3, 1)
        rows.append({'image': item['file'], 'teacher_vs_student_int8': metrics(target[None], actual[None]),
                     'student_float_vs_int8': metrics(floating, actual[None]),
                     'cpu_reference_seconds': elapsed})
        if index < 3:
            small = np.asarray(Image.fromarray(x).resize((128, 128), Image.Resampling.BILINEAR))
            old = dequantize(predict(native, small), nq)
            old = np.asarray(Image.fromarray(np.rint(old).astype(np.uint8)).resize((640, 480), Image.Resampling.NEAREST))
            tiles = np.concatenate((x, old, target, actual), axis=1)
            canvas = Image.new('RGB', (2560, 510), '#eeeeee')
            canvas.paste(Image.fromarray(np.rint(tiles).clip(0, 255).astype(np.uint8)), (0, 30))
            draw = ImageDraw.Draw(canvas)
            for k, label in enumerate(['input', 'original 128x128 enlarged', 'same weights at 640x480', 'trained student 640x480 INT8']):
                draw.text((640*k+8, 8), label, fill='black')
            canvas.save(images/f'validation-{index}.png')
        if index % 8 == 0:
            print(json.dumps({'stage': 'validation', 'image': index, 'psnr': rows[-1]['teacher_vs_student_int8']['psnr_255_db']}), flush=True)
    teacher = runtime(out/'teacher/rain_princess_640x480_int8.tflite')
    for name, value in [('black', 0), ('white', 255)]:
        x = np.full((480, 640, 3), value, np.uint8)
        target = dequantize(predict(teacher, x), manifest['teacher_output_quantization'])
        actual = dequantize(predict(rt, x), oq)
        tile = np.concatenate((x, target, actual), axis=1)
        Image.fromarray(np.rint(tile).astype(np.uint8)).save(images/f'{name}.png')
    report = {'scope': 'CPU pilot; teacher fidelity is not subjective style quality or HDMI acceptance',
              'candidate': CANDIDATE, 'training_steps': ckpt['steps'], 'patch': ckpt['patch'],
              'training_seconds': ckpt['training_seconds'], 'validation_images': len(rows),
              'teacher_vs_student_mean_psnr_db': float(np.mean([r['teacher_vs_student_int8']['psnr_255_db'] for r in rows])),
              'teacher_vs_student_mean_local_ssim': float(np.mean([r['teacher_vs_student_int8']['local_gaussian_ssim'] for r in rows])),
              'student_float_vs_int8_mean_psnr_db': float(np.mean([r['student_float_vs_int8']['psnr_255_db'] for r in rows])),
              'model_sha256': digest(out/'rain_student_640x480_int8.tflite'),
              'teacher_sha256': manifest['teacher_sha256'],
              'hardware_proven': False, 'per_image': rows}
    save_json(out/'evaluation.json', report)
    print(json.dumps({k: v for k, v in report.items() if k != 'per_image'}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'train', 'export', 'evaluate'])
    parser.add_argument('--output', type=Path, default=ROOT/'build/rain640_trial')
    parser.add_argument('--steps', type=int, default=1200)
    parser.add_argument('--patch', type=int, default=256)
    parser.add_argument('--batch', type=int, default=4)
    args = parser.parse_args()
    globals()[args.action](args)


if __name__ == '__main__':
    main()
