#!/usr/bin/env python3
"""Pack unchanged INT8 Conv weights for the 8x8 row-cached backend.

Requires numpy, flatbuffers and tflite; --fixtures also uses tflite-runtime.
This is a layout conversion, with no training or quantization of weights.
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

import numpy as np
import tflite


def quantize_multiplier(value):
    significand, shift = math.frexp(value)
    multiplier = math.floor(significand * (1 << 31) + .5)
    if multiplier == 1 << 31:
        multiplier //= 2
        shift += 1
    if shift < -31:
        return 0, 0
    if not -31 <= shift <= 7:
        raise ValueError('unsupported quantized multiplier shift')
    return multiplier, shift


def compile_model(blob):
    model = tflite.Model.GetRootAsModel(blob, 0)
    if model.SubgraphsLength() != 1:
        raise ValueError('expected one graph')
    graph = model.Subgraphs(0)
    layers, packed = [], bytearray()
    for node in range(graph.OperatorsLength()):
        op = graph.Operators(node)
        code = model.OperatorCodes(op.OpcodeIndex()).BuiltinCode()
        if code != tflite.BuiltinOperator.CONV_2D:
            if code not in (tflite.BuiltinOperator.ADD,
                            tflite.BuiltinOperator.RESIZE_NEAREST_NEIGHBOR):
                raise ValueError('unsupported graph operation')
            continue
        ti, tw, tb = [graph.Tensors(int(i)) for i in op.InputsAsNumpy()]
        to = graph.Tensors(op.Outputs(0))
        shape = list(map(int, tw.ShapeAsNumpy()))
        co, kh, kw, ci = shape
        ins, outs = list(map(int, ti.ShapeAsNumpy())), list(map(int, to.ShapeAsNumpy()))
        opts = tflite.Conv2DOptions()
        opts.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
        stride = opts.StrideH()
        if (shape[1:3] != [3, 3] or ci not in (3, 8, 16, 32) or
                co not in (3, 8, 16, 32) or ins[0] != 1 or
                not 1 <= ins[1] <= 128 or not 1 <= ins[2] <= 128 or
                ins[1] % 2 or ins[2] % 2 or
                opts.Padding() != tflite.Padding.SAME or stride not in (1, 2) or
                opts.StrideW() != stride or opts.DilationHFactor() != 1 or
                opts.DilationWFactor() != 1 or
                outs != [1, ins[1] // stride, ins[2] // stride, co]):
            raise ValueError(f'unsupported Conv shape/options at {node}')
        for tensor in (ti, tw, to):
            if tensor.Type() != tflite.TensorType.INT8:
                raise ValueError('expected INT8 tensors')
        qi, qw, qo = ti.Quantization(), tw.Quantization(), to.Quantization()
        if qw.ScaleLength() != co or np.any(qw.ZeroPointAsNumpy() != 0):
            raise ValueError('expected symmetric per-channel weights')
        iz, oz = int(qi.ZeroPoint(0)), int(qo.ZeroPoint(0))
        activation = opts.FusedActivationFunction()
        if activation not in (tflite.ActivationFunctionType.NONE, tflite.ActivationFunctionType.RELU):
            raise ValueError('unsupported fused activation')
        minimum = oz if activation == tflite.ActivationFunctionType.RELU else -128
        weights = np.frombuffer(model.Buffers(tw.Buffer()).DataAsNumpy(), np.int8).reshape(shape)
        bias = np.frombuffer(model.Buffers(tb.Buffer()).DataAsNumpy(), '<i4')
        padded = np.zeros(((co+7)//8*8, 3, 3, (ci+7)//8*8), np.int8)
        padded[:co, :, :, :ci] = weights
        # [output group, ky, kx, input group, output lane, input lane].
        data = padded.reshape((co+7)//8, 8, 3, 3, (ci+7)//8, 8).transpose(0, 2, 3, 4, 1, 5).tobytes()
        buffer = model.Buffers(tw.Buffer())
        offset = buffer._tab.Vector(buffer._tab.Offset(4))
        if blob[offset:offset+weights.size] != weights.tobytes():
            raise ValueError('filter byte offset verification failed')
        mult, shifts = zip(*(quantize_multiplier(float(qi.Scale(0))*float(qw.Scale(c))/float(qo.Scale(0))) for c in range(co)))
        params = [0]*96
        params[:co] = map(int, bias)
        params[32:32+co] = mult
        params[64:64+co] = shifts
        fnv = 0x811c9dc5
        for value in weights.tobytes():
            fnv = ((fnv ^ value)*0x01000193) & 0xffffffff
        layers.append(dict(node=node, input_tensor=int(op.Inputs(0)), output_tensor=int(op.Outputs(0)),
                           input_shape=ins, output_shape=outs, stride=stride,
                           input_zero=iz, output_zero=oz, activation_min=minimum, activation_max=127,
                           filter_offset=offset, filter_bytes=weights.size, filter_fnv=fnv,
                           packed_offset=len(packed), packed_bytes=len(data),
                           parameters=params))
        packed.extend(data)
    return layers, bytes(packed)


def mem(path, data, word_bytes):
    if len(data) % word_bytes:
        raise ValueError('unaligned fixture')
    path.write_text(''.join(f'{int.from_bytes(data[i:i+word_bytes], "little"):0{word_bytes*2}x}\n'
                            for i in range(0, len(data), word_bytes)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--fixtures', action='store_true')
    args = parser.parse_args()
    blob = args.model.read_bytes()
    layers, packed = compile_model(blob)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output/'weights.bin').write_bytes(packed)
    header = '#pragma once\n#include <stdint.h>\n'
    header += 'struct IrisRainFilter { uint32_t model_offset, packed_offset, bytes, filter_bytes, fnv; };\n'
    header += 'alignas(16) static const unsigned char iris_rain_weights[] = {\n'
    header += '\n'.join(','.join(f'0x{v:02x}' for v in packed[i:i+32])+',' for i in range(0, len(packed), 32))+'\n};\n'
    header += 'static const IrisRainFilter iris_rain_filters[] = {\n'
    header += ''.join('{%du,%du,%du,%du,%du},\n' % (r['filter_offset'], r['packed_offset'], r['packed_bytes'], r['filter_bytes'], r['filter_fnv']) for r in layers)+'};\n'
    (args.output/'rain_backend_model.h').write_text(header)
    if args.fixtures:
        from tflite_runtime.interpreter import Interpreter, OpResolverType
        model = tflite.Model.GetRootAsModel(blob, 0)
        graph = model.Subgraphs(0)
        # TFLite can perform Add in place even with preserve_all_tensors.
        # Expose every intermediate as a graph output in a reference-only
        # copy, preventing overwrite of a Conv result/Add operand. Weights,
        # operators and their options remain byte-for-byte unchanged.
        reference_blob = bytearray(blob)
        reference_blob.extend(bytes((-len(reference_blob)) % 4))
        vector = len(reference_blob)
        outputs = [int(graph.Operators(n).Outputs(0)) for n in range(graph.OperatorsLength())]
        reference_blob.extend(struct.pack('<I', len(outputs)))
        reference_blob.extend(struct.pack('<'+'i'*len(outputs), *outputs))
        field = graph._tab.Pos + graph._tab.Offset(8)
        struct.pack_into('<I', reference_blob, field, vector-field)
        engine = Interpreter(model_content=bytes(reference_blob), experimental_preserve_all_tensors=True,
                             experimental_op_resolver_type=OpResolverType.BUILTIN_REF)
        engine.allocate_tensors()
        inp = engine.get_input_details()[0]
        pixels = np.random.default_rng(20261020).integers(-128, 128, inp['shape'], dtype=np.int8)
        engine.set_tensor(inp['index'], pixels)
        engine.invoke()
        original = Interpreter(model_content=blob, experimental_op_resolver_type=OpResolverType.BUILTIN_REF)
        original.allocate_tensors()
        original.set_tensor(inp['index'], pixels)
        original.invoke()
        final_index = int(graph.Outputs(0))
        if not np.array_equal(engine.get_tensor(final_index), original.get_tensor(final_index)):
            raise ValueError('intermediate-preserving reference differs from original model')
        for r in layers:
            dest = args.output / str(r['node'])
            dest.mkdir(exist_ok=True)
            for label, tensor in [('input', r['input_tensor']), ('output', r['output_tensor'])]:
                data = engine.get_tensor(tensor)[0]
                n = data.shape[-1]
                padded = np.zeros((*data.shape[:-1], (n+7)//8*8), np.int8)
                padded[..., :n] = data
                mem(dest/(label+'.mem'), padded.tobytes(), 8)
                (dest/(label+'.bin')).write_bytes(data.tobytes())
            begin = r['packed_offset']
            mem(dest/'weights.mem', packed[begin:begin+r['packed_bytes']], 16)
            mem(dest/'parameters.mem', b''.join((v & 0xffffffff).to_bytes(4, 'little') for v in r['parameters']), 4)
            config = [r['input_shape'][2], r['input_shape'][1], r['input_shape'][3],
                      r['output_shape'][3], r['stride']==2, r['input_zero'] & 255,
                      r['output_zero'] & 255, r['activation_min'] & 255, 127, r['packed_bytes']//16]
            mem(dest/'config.mem', bytes(v & 255 for v in config), 1)
        model = tflite.Model.GetRootAsModel(blob, 0)
        graph = model.Subgraphs(0)
        for node in range(graph.OperatorsLength()):
            op = graph.Operators(node)
            if model.OperatorCodes(op.OpcodeIndex()).BuiltinCode() != tflite.BuiltinOperator.ADD:
                continue
            ta, tb = (graph.Tensors(int(i)) for i in op.InputsAsNumpy())
            to = graph.Tensors(op.Outputs(0))
            qa, qb, qo = ta.Quantization(), tb.Quantization(), to.Quantization()
            twice = 2*max(float(qa.Scale(0)), float(qb.Scale(0)))
            ma, sa = quantize_multiplier(float(qa.Scale(0))/twice)
            mb, sb = quantize_multiplier(float(qb.Scale(0))/twice)
            mo, so = quantize_multiplier(twice/((1 << 20)*float(qo.Scale(0))))
            opts = tflite.AddOptions()
            opts.Init(op.BuiltinOptions().Bytes, op.BuiltinOptions().Pos)
            activation = opts.FusedActivationFunction()
            if activation not in (tflite.ActivationFunctionType.NONE, tflite.ActivationFunctionType.RELU):
                raise ValueError('unsupported Add activation')
            minimum = int(qo.ZeroPoint(0)) if activation == tflite.ActivationFunctionType.RELU else -128
            size = int(np.prod(to.ShapeAsNumpy()))
            params = [0x50ff0, size, -int(qa.ZeroPoint(0)), -int(qb.ZeroPoint(0)), int(qo.ZeroPoint(0)),
                      ma, sa, mb, sb, mo, so, 20, minimum, 127]
            dest = args.output / ('add-'+str(node))
            dest.mkdir(exist_ok=True)
            for label, index in [('a', op.Inputs(0)), ('b', op.Inputs(1)), ('output', op.Outputs(0))]:
                mem(dest/(label+'.mem'), engine.get_tensor(index).tobytes(), 1)
            mem(dest/'parameters.mem', b''.join((v & 0xffffffff).to_bytes(4, 'little') for v in params), 4)
    report = dict(model_sha256=hashlib.sha256(blob).hexdigest(),
                  packed_sha256=hashlib.sha256(packed).hexdigest(), packed_bytes=len(packed),
                  model_changed=False, layers=layers, hardware_verified=False)
    (args.output/'rain-backend.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='layers'}, indent=2))


if __name__ == '__main__':
    main()
