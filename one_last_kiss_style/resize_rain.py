#!/usr/bin/env python3
"""Create a separate spatial-size trial, preserving all learned INT8 data.

This does not retrain or recalibrate the model. Only activation dimensions and
the two nearest-neighbor resize sizes change. The result is for host experiments;
the current FPGA backend does not support 640x480.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import tflite


def sha256(blob):
    return hashlib.sha256(blob).hexdigest()


def resize_model(source, height, width):
    if height <= 0 or width <= 0 or height % 4 or width % 4:
        raise ValueError('height and width must be positive multiples of four')
    data = bytearray(source)
    model = tflite.Model.GetRootAsModel(data, 0)
    if model.SubgraphsLength() != 1:
        raise ValueError('expected one subgraph')
    graph = model.Subgraphs(0)
    inp = graph.Tensors(graph.Inputs(0))
    native = inp.ShapeAsNumpy().copy()
    if native.shape != (4,) or native[0] != 1 or native[3] != 3:
        raise ValueError('expected batch-one RGB input')
    features = {int(i) for i in graph.InputsAsNumpy()}
    resizes = []
    for i in range(graph.OperatorsLength()):
        op = graph.Operators(i)
        code = model.OperatorCodes(op.OpcodeIndex()).BuiltinCode()
        if code not in (tflite.BuiltinOperator.CONV_2D,
                        tflite.BuiltinOperator.ADD,
                        tflite.BuiltinOperator.RESIZE_NEAREST_NEIGHBOR):
            raise ValueError(f'unsupported operation at {i}')
        features.update(int(j) for j in op.OutputsAsNumpy())
        if code == tflite.BuiltinOperator.RESIZE_NEAREST_NEIGHBOR:
            resizes.append((i, int(op.Inputs(1)), int(op.Outputs(0))))
    if len(resizes) != 2:
        raise ValueError('expected two nearest-neighbor upsampling stages')
    changes = []
    for index in sorted(features):
        tensor = graph.Tensors(index)
        shape = tensor.ShapeAsNumpy()
        if shape.shape != (4,) or shape[0] != 1:
            raise ValueError(f'unsupported activation shape at tensor {index}')
        before = shape.copy()
        h, hr = divmod(int(before[1]) * height, int(native[1]))
        w, wr = divmod(int(before[2]) * width, int(native[2]))
        if hr or wr:
            raise ValueError('nonintegral feature dimensions')
        shape[1:3] = (h, w)
        if tensor.ShapeSignatureLength():
            signature = tensor.ShapeSignatureAsNumpy()
            if not np.array_equal(signature, before):
                raise ValueError('dynamic shape signatures are unsupported')
            signature[:] = shape
        changes.append({'tensor': index, 'before': before.tolist(),
                        'after': shape.tolist()})
    changed_buffers = set()
    resize_changes = []
    for node, size_index, output_index in resizes:
        size_tensor = graph.Tensors(size_index)
        if size_tensor.Type() != tflite.TensorType.INT32:
            raise ValueError('expected int32 resize size')
        buf_index = size_tensor.Buffer()
        size = model.Buffers(buf_index).DataAsNumpy().view('<i4')
        if size.shape != (2,):
            raise ValueError('expected constant height/width resize size')
        before = size.copy()
        size[:] = graph.Tensors(output_index).ShapeAsNumpy()[1:3]
        changed_buffers.add(buf_index)
        resize_changes.append({'node': node, 'buffer': int(buf_index),
                               'before': before.tolist(), 'after': size.tolist()})
    original = tflite.Model.GetRootAsModel(source, 0)
    unchanged = 0
    for i in range(model.BuffersLength()):
        if i in changed_buffers:
            continue
        old, new = original.Buffers(i), model.Buffers(i)
        if old.DataLength() != new.DataLength():
            raise ValueError('buffer length changed')
        if old.DataLength() and not np.array_equal(old.DataAsNumpy(), new.DataAsNumpy()):
            raise ValueError(f'non-size constant buffer {i} changed')
        unchanged += 1
    # No reserialization: each changed byte must belong to a shape or size above.
    # All quantization tables, operator options, weights and biases stay intact.
    return bytes(data), {'source_shape': native.tolist(),
                         'target_shape': [1, height, width, 3],
                         'activation_shapes': changes, 'resize_sizes': resize_changes,
                         'unchanged_non_size_buffers': unchanged}


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path,
                        default=root/'models/rain-princess-cropped_style_int8.tflite')
    parser.add_argument('--height', type=int, default=480)
    parser.add_argument('--width', type=int, default=640)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.model.resolve() == args.output.resolve() or args.output.exists():
        raise ValueError('output must be a new, separate file')
    original = args.model.read_bytes()
    resized, report = resize_model(original, args.height, args.width)
    original_shape = report['source_shape']
    restored, _ = resize_model(resized, original_shape[1], original_shape[2])
    if restored != original:
        raise RuntimeError('round-trip model is not byte-identical')
    from tflite_runtime.interpreter import Interpreter, OpResolverType
    runtime = Interpreter(model_content=resized,
                          experimental_op_resolver_type=OpResolverType.BUILTIN_REF)
    runtime.allocate_tensors()
    for details in (runtime.get_input_details(), runtime.get_output_details()):
        if details[0]['shape'].tolist() != report['target_shape']:
            raise RuntimeError('runtime shape differs')
    report.update({'source': str(args.model.resolve()), 'source_sha256': sha256(original),
                   'output_sha256': sha256(resized), 'round_trip_byte_identical': True,
                   'weights_biases_quantization_unchanged': True,
                   'trained': False, 'hardware_proven': False})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(resized)
    args.output.with_suffix('.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in ('source_shape', 'target_shape',
                     'source_sha256', 'output_sha256', 'round_trip_byte_identical')}))


if __name__ == '__main__':
    main()
