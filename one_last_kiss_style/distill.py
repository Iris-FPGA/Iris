#!/usr/bin/env python3
"""Reconstruct the frozen INT8 teacher and distill bounded Ti60 candidates.

Run with .venv-style/bin/python. Data, checkpoints and reports are ignored build
artifacts; the original TFLite model is never overwritten.
"""
import argparse
import hashlib
import json
import random
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image
import tflite
import torch
from torch import nn
from torch.nn import functional as F

ROOT = Path(__file__).resolve().parent
MODEL = ROOT / 'one_last_kiss_0_int8.tflite'
CANDIDATES = {'c488_r1': ((4, 8, 8), 1), 'c448_r1': ((4, 4, 8), 1),
              'c448_r0': ((4, 4, 8), 0), 'c488_skip_r1': ((4, 8, 8), 1, True),
              'c448_lowdec_skip_r0': ((4, 4, 8), 0, True, True)}


class Teacher(nn.Module):
    def __init__(self):
        super().__init__()
        self.flatbuffer = MODEL.read_bytes()
        m = tflite.Model.GetRootAsModel(self.flatbuffer, 0)
        g = m.Subgraphs(0)
        self.ops = []
        for i in range(g.OperatorsLength()):
            op = g.Operators(i)
            kind = m.OperatorCodes(op.OpcodeIndex()).BuiltinCode()
            ins = list(op.InputsAsNumpy())
            out = int(op.Outputs(0))
            q = g.Tensors(out).Quantization()
            quant = (float(q.Scale(0)), int(q.ZeroPoint(0)))
            if kind == tflite.BuiltinOperator.CONV_2D:
                opts = tflite.Conv2DOptions()
                opts.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
                def constant(index):
                    t = g.Tensors(index)
                    raw = m.Buffers(t.Buffer()).DataAsNumpy().tobytes()
                    dtype = np.int8 if t.Type() == tflite.TensorType.INT8 else np.int32
                    a = np.frombuffer(raw, dtype).reshape(t.ShapeAsNumpy()).copy()
                    tq = t.Quantization()
                    shape = [1] * a.ndim
                    shape[tq.QuantizedDimension()] = tq.ScaleLength()
                    scale = tq.ScaleAsNumpy().reshape(shape)
                    zp = tq.ZeroPointAsNumpy().reshape(shape)
                    return (a.astype(np.float32) - zp) * scale
                self.register_buffer(f'w{i}', torch.from_numpy(constant(ins[1]).transpose(0, 3, 1, 2)).float())
                self.register_buffer(f'b{i}', torch.from_numpy(constant(ins[2])).float())
                extra = (opts.StrideH(), opts.StrideW(), opts.FusedActivationFunction())
            elif kind in (tflite.BuiltinOperator.ADD, tflite.BuiltinOperator.RESIZE_NEAREST_NEIGHBOR):
                extra = None
            else:
                raise ValueError(f'Unsupported teacher op {kind}')
            self.ops.append((i, kind, ins, out, quant, extra))
        self.output_index = int(g.Outputs(0))

    @torch.no_grad()
    def forward(self, rgb):
        tensors = {0: rgb}
        for i, kind, ins, out, (scale, zp), extra in self.ops:
            a = tensors[ins[0]]
            if kind == tflite.BuiltinOperator.CONV_2D:
                sh, sw, activation = extra
                h, w = a.shape[-2:]
                ph, pw = max(0, ((h+sh-1)//sh-1)*sh+3-h), max(0, ((w+sw-1)//sw-1)*sw+3-w)
                a = F.conv2d(F.pad(a, (pw//2, pw-pw//2, ph//2, ph-ph//2)),
                             getattr(self, f'w{i}'), getattr(self, f'b{i}'), (sh, sw))
                if activation == tflite.ActivationFunctionType.RELU:
                    a = F.relu(a)
                elif activation != tflite.ActivationFunctionType.NONE:
                    raise ValueError('Unsupported fused activation')
            elif kind == tflite.BuiltinOperator.ADD:
                a = a + tensors[ins[1]]
            else:
                a = F.interpolate(a, scale_factor=2, mode='nearest')
            # Fixed INT8 quantizers preserve the teacher's original calibration.
            tensors[out] = (torch.round(a / scale + zp).clamp(-128, 127) - zp) * scale
        return tensors[self.output_index]


class Conv(nn.Module):
    def __init__(self, cin, cout, stride=1, activation=True, bn=True, kernel=3):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, kernel, stride=stride, bias=True)
        self.kernel = kernel
        self.bn = nn.BatchNorm2d(cout) if bn else nn.Identity()
        self.activation = activation
        self.stride = stride

    def forward(self, x):
        h, w = x.shape[-2:]
        s = self.stride
        ph, pw = max(0, ((h+s-1)//s-1)*s+self.kernel-h), max(0, ((w+s-1)//s-1)*s+self.kernel-w)
        x = self.bn(self.conv(F.pad(x, (pw//2, pw-pw//2, ph//2, ph-ph//2))))
        return F.relu(x) if self.activation else x

    def folded(self):
        w, b = self.conv.weight.detach(), self.conv.bias.detach()
        if isinstance(self.bn, nn.BatchNorm2d):
            scale = self.bn.weight.detach() / torch.sqrt(self.bn.running_var + self.bn.eps)
            w = w * scale[:, None, None, None]
            b = (b - self.bn.running_mean) * scale + self.bn.bias.detach()
        return w.cpu().numpy().transpose(2, 3, 1, 0), b.cpu().numpy()


class Student(nn.Module):
    def __init__(self, channels, residuals, skip=False, low_decoder=False):
        super().__init__()
        a, b, c = channels
        self.skip = skip
        self.low_decoder = low_decoder
        self.enc = nn.ModuleList([Conv(3, a), Conv(a, b, 2), Conv(b, c, 2)])
        self.res = nn.ModuleList([nn.ModuleList([Conv(c, c), Conv(c, c, activation=False)]) for _ in range(residuals)])
        self.dec = nn.ModuleList([Conv(c, b), Conv(b, a),
                                 Conv(a, 3, activation=False, bn=False, kernel=1 if low_decoder else 3)])

    def forward(self, rgb):
        x = rgb / 255.0
        enc = []
        for layer in self.enc:
            x = layer(x); enc.append(x)
        for one, two in self.res: x = x + two(one(x))
        for k, layer in enumerate(self.dec[:2]):
            x = F.interpolate(layer(x), scale_factor=2, mode='nearest') if self.low_decoder else layer(F.interpolate(x, scale_factor=2, mode='nearest'))
            if self.skip: x = x + enc[1-k]
        return self.dec[2](x) * 255.0


def dataset():
    directory = ROOT / 'data'
    with zipfile.ZipFile(directory / 'coco128.zip') as z:
        for entry in z.infolist():
            if '..' in Path(entry.filename).parts or Path(entry.filename).is_absolute():
                raise ValueError('Unsafe archive path')
        z.extractall(directory)
    files = sorted((directory / 'coco128/images/train2017').glob('*.jpg'))
    if len(files) != 128: raise ValueError(f'Expected 128 public COCO images, got {len(files)}')
    random.Random(20261007).shuffle(files)
    splits = {'train': files[:80], 'calibration': files[80:96], 'validation': files[96:]}
    return splits


def image(path, size, rng=None):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    side = min(w, h)
    if rng:
        side = max(64, int(side * rng.uniform(.5, 1)))
        x, y = rng.randrange(w-side+1), rng.randrange(h-side+1)
    else:
        x, y = (w-side)//2, (h-side)//2
    im = im.crop((x, y, x+side, y+side)).resize((size, size), Image.Resampling.BILINEAR)
    if rng and rng.random() < .5: im = im.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    return np.array(im, dtype=np.float32)


def validate_teacher(teacher, device, output):
    import tensorflow as tf
    runtime = tf.lite.Interpreter(model_path=str(MODEL), experimental_op_resolver_type=tf.lite.experimental.OpResolverType.BUILTIN_REF)
    runtime.allocate_tensors()
    iq, oq = runtime.get_input_details()[0], runtime.get_output_details()[0]
    y, x = np.indices((128, 128))
    fixtures = [np.stack((2*x, 2*y, np.where(((x//16) ^ (y//16)) & 1, 255, 0)), -1).astype(np.float32),
                np.random.default_rng(20261007).integers(0, 256, (128, 128, 3)).astype(np.float32)]
    records = []
    for k, rgb in enumerate(fixtures):
        runtime.set_tensor(iq['index'], (rgb-128).astype(np.int8)[None]); runtime.invoke()
        q = runtime.get_tensor(oq['index'])
        ref = (q.astype(np.float32) - oq['quantization'][1]) * oq['quantization'][0]
        pred = teacher(torch.from_numpy(rgb.transpose(2, 0, 1)[None]).to(device)).cpu().numpy().transpose(0, 2, 3, 1)
        e = pred.astype(np.float64) - ref
        record = {'fixture': k, 'max_abs': float(abs(e).max()), 'mae': float(abs(e).mean()),
                  'psnr_255_db': float(10*np.log10(255**2/max(float((e*e).mean()), 1e-15)))}
        records.append(record)
        q.tofile(output / f'golden-{k}.bin')
    # This reconstructed teacher is for distillation; exact TFLite stays the
    # numerical oracle for FPGA parity. Do not silently train on a broken graph.
    (output / 'teacher-parity.json').write_text(json.dumps(records, indent=2)+'\n')
    if min(r['psnr_255_db'] for r in records) < 35: raise RuntimeError(records)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--steps', type=int, default=4000)
    p.add_argument('--batch', type=int, default=8)
    p.add_argument('--device', default='cuda')
    p.add_argument('--validate-only', action='store_true')
    a = p.parse_args()
    random.seed(20261007); np.random.seed(20261007); torch.manual_seed(20261007)
    torch.set_num_threads(4)
    output = ROOT / 'build'; output.mkdir(exist_ok=True)
    teacher = Teacher().to(a.device).eval()
    validate_teacher(teacher, a.device, output)
    if a.validate_only: return
    splits = dataset()
    manifest = {'teacher_sha256': hashlib.sha256(MODEL.read_bytes()).hexdigest(),
                'seed': 20261007, 'source': 'https://github.com/ultralytics/assets/releases/download/v0.0.0/coco128.zip',
                'splits': {k: [{'name': f.name, 'sha256': hashlib.sha256(f.read_bytes()).hexdigest()} for f in fs] for k, fs in splits.items()}}
    (output / 'data-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    students = {n: Student(*spec).to(a.device) for n, spec in CANDIDATES.items()}
    optim = {n: torch.optim.Adam(m.parameters(), lr=1e-3) for n, m in students.items()}
    rng = random.Random(20261007)
    for step in range(a.steps):
        size = 128 if step < a.steps*3//4 else 256
        batch = np.stack([image(rng.choice(splits['train']), size, rng) for _ in range(a.batch)])
        x = torch.from_numpy(batch.transpose(0, 3, 1, 2)).to(a.device)
        target = teacher(x).clamp(0, 255)
        losses = {}
        for name, model in students.items():
            optim[name].zero_grad(set_to_none=True)
            pred = model(x)
            loss = F.l1_loss(pred / 255, target / 255)
            # Preserve contours as well as colors without an extra deployed op.
            loss = loss + .25 * F.l1_loss((pred[:, :, :, 1:]-pred[:, :, :, :-1])/255,
                                         (target[:, :, :, 1:]-target[:, :, :, :-1])/255)
            loss.backward(); nn.utils.clip_grad_norm_(model.parameters(), 1); optim[name].step()
            losses[name] = round(float(loss), 5)
        if step % 50 == 0 or step == a.steps-1:
            print(json.dumps({'step': step, 'size': size, 'loss': losses}), flush=True)
        if (step+1) % 500 == 0 or step == a.steps-1:
            for name, model in students.items():
                torch.save({'state_dict': model.state_dict(), 'candidate': name, 'step': step,
                            'teacher_sha256': manifest['teacher_sha256']}, output / f'{name}.pt')


if __name__ == '__main__': main()
