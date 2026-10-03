# out/ —— 参考产物

这些是**证据文件**，不是交付物本身（交付物是 `deploy/` 里的工具链，模型可以用它重新生成）。
放进来是为了让 review 的人**不用装任何环境**就能自己核实结论。

| 文件 | 说明 |
|---|---|
| `flatfns_trained_int8.tflite` | 合规的 INT8 模型（**22 KB**）。128×128 输入，`CONV_2D×8 + ADD×3` |
| `flatfns_trained_int8_compare.png` | 上面这个模型的输出图（只训了 1 epoch，画质无意义，仅证明链路通） |
| `compliance_flatfns_trained.md` | 它的 G2/G3 合规报告 |
| `preflight_160x120_int8.tflite` | **部署分辨率**版本：输入 `1×120×160×3` INT8（×4 正好到 640×480） |
| `preflight_160x120_compliance.md` | 它的合规报告 |
| `preflight_160x120_stylized.jpg` | 它的风格化样图 |
| `batch_results_example.csv` | 跑批汇总表样例（含资源估算列） |
| `smoke-test-报告.md` | 用**队友的脚本**转**原版模型**的实测记录 —— 93 个非白名单算子的证据来源 |

## 自己复核（不需要 GPU、不需要 Efinity）

```bash
# 只需要一个 Python 环境
pip install ai_edge_litert

# 算子白名单门禁（G2/G3）—— 会解析 flatbuffer
python deploy/verify/ops_inventory.py --model deploy/out/flatfns_trained_int8.tflite

# 厂商工具复核 + 资源估算（G5）—— 用 tinyml 仓库里自带的官方二进制与官方公式
python deploy/verify/tinyml_report.py --model deploy/out/flatfns_trained_int8.tflite \
       --in-parallel 8 16 32
```

`tinyml_report.py` 需要先克隆 `Efinix-Inc/tinyml`，或设 `TINYML_GENERATOR_DIR` 环境变量。

**反证**：拿 `examples@Iris` 的 `one_last_kiss_style.model` 走一遍队友的
`model2tf_lite.py`，再用 `ops_inventory.py` 检查，会报 8 项违规并 exit 1 —— 见 `smoke-test-报告.md`。

## 这些文件怎么重新生成

```bash
deploy/env/setup-convert-env.sh && source deploy/.venv/bin/activate
python deploy/train/export_onnx.py --out out/f.onnx --size 160x120          # 随机权重即可验证链路
python deploy/quant/to_tflite.py --onnx out/f.onnx --calib <校准图> --out out/f_int8.tflite
python deploy/verify/ops_inventory.py --model out/f_int8.tflite --report out/compliance.md
```
