# 算子合规报告

模型：`/mnt/mydata/Iris/deploy/out/preflight/preflight_c16b3_int8.tflite`（22.0 KB）

schema version: 3

## G2 算子清单

| 算子 | 个数 | version | 白名单 |
|---|---:|---:|:--:|
| `CONV_2D` | 8 | 3 | ✅ |
| `ADD` | 3 | 2 | ✅ |

## G3 输入/输出

| 张量 | dtype | shape | scale | zero_point |
|---|---|---|---:|---:|
| 输入 `serving_default_input:0` | INT8 | [1, 120, 160, 3] | 1 | -128 |
| 输出 `PartitionedCall:0` | INT8 | [1, 120, 160, 3] | 0.84963739 | 47 |

## 结论

**通过**：G2 算子全部位于 TinyML 加速白名单；G3 全整数 INT8。
