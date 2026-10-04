# 环境配置说明（三条独立环境）

> 结论先行：**队友的"环境已配好"指的是他自己那台机器上的 PyTorch-only 环境**
> （`Iris/docs/风格迁移_模型核对与FPGA方案.md:125` 的 conda env `yolo`），
> 那句话的上下文是他**放弃 TFLite 路线**之后走自研 INT8 加速器，所以"零新增依赖"。
> 走 TinyML/TFLite 路线，**训练、转换、板端必须各配一套**。

---

## 环境总览

| # | 环境 | 在哪 | 干什么 | 状态 |
|---|---|---|---|---|
| A | 转换 / 量化 | **本机**（CPU 足够） | `.model` → ONNX → INT8 `.tflite` → 算子合规校验 | 见 `setup-convert-env.sh` |
| B | 训练 | **算力自由 GPU 云主机** | 训练 TinyML 友好网络 | 见 `requirements-train.txt` |
| C | 板端 | 本机（需装在 `/mnt/mydata`） | TinyML Generator + Efinity 编译烧录 | 阻塞：安装包需 Efinity 账号下载 |

**为什么不能只用一套**：`examples/Iris:fast_neural_style/requirements.txt` 只有
`numpy / torch>=2.6 / torchvision` 三行——**没有 TensorFlow**。
而 `script/model2tf_lite.py` 要 import `tensorflow`、`onnxruntime`，还要外部调用 `onnx2tf`。
（这正是 `Iris/docs/TinyML模型训练量化与Ti60F225部署计划.md:230` 那句
"不要因为训练环境能加载 `.model`，就认为它能够运行 TensorFlow/TFLite Converter"。）

---

## A. 本机转换环境

```bash
deploy/env/setup-convert-env.sh          # 一键：建 venv + 装依赖 + 验证
source deploy/.venv/bin/activate
```

装了什么：

| 包 | 用途 |
|---|---|
| `tensorflow-cpu` | `TFLiteConverter`（全整数量化）+ `tf.lite.Interpreter`（算子清单） |
| `onnx` / `onnxruntime` | 读 ONNX 图做 **G1 门禁**；与 PyTorch 输出比对 |
| `onnx2tf` | ONNX → TF SavedModel（官方 `docs/pytorch_tflite_flow.md` 的路径） |
| `torch` / `torchvision`（CPU） | 加载 `.model`（`torch.load`）并导出 ONNX |
| `pillow` / `numpy` / `opencv-python-headless` | 校准集与图片读写 |
| `scikit-image` | PSNR / SSIM 精度报告（**G4 门禁**） |

细节：
- `torch` 走 `https://download.pytorch.org/whl/cpu`，避免默认源拉 ~3 GB 的 CUDA 依赖；
- 其余走清华源 `https://pypi.tuna.tsinghua.edu.cn/simple`；
- `PIP_CACHE_DIR` 指向 `deploy/.pip-cache`（工作区内，避免写 `~/.cache` 被拦）。

环境变量（可选，避免每次 source）：

```bash
export PATH="/mnt/mydata/Iris/deploy/.venv/bin:$PATH"
```

---

## B. 算力自由 GPU 云主机（训练）

队友的 `examples/Iris:fast_neural_style/script/para.py:3` 写死了云主机路径：

```
/root/gpufree-data/FPGA/examples/fast_neural_style/model/one_last_kiss_style.model
```

说明云主机上有个持久化目录 **`/root/gpufree-data/`**——代码和数据集放这里，实例重启不丢。

```bash
# 1) 上传/克隆代码到持久目录
cd /root/gpufree-data/FPGA
git clone -b Iris https://github.com/FinResect/examples.git

# 2) 装训练依赖（云主机镜像一般自带 torch+CUDA，先确认再装）
pip install -r /path/to/deploy/env/requirements-train.txt

# 3) 确认 GPU 可用
python -c "import torch; print(torch.__version__, torch.cuda.is_available())"

# 4) 训练（沿用队友的用法；注意 --width 推理时必须一致）
cd examples/fast_neural_style
python neural_style/neural_style.py train \
  --dataset /root/gpufree-data/coco/train2014 \
  --style-image images/style-images/one_last_kiss.png \
  --save-model-dir /root/gpufree-data/runs/ol_kiss \
  --epochs 2 --width 0.25 --accel
```

> 注意 `使用说明.md:44`：`--dataset` 要指向"内部还含一层子文件夹"的目录
> （`ImageFolder` 按类别分子文件夹），例如 `/path/train-dataset/train2014/*.jpg`。

素材从哪来（本机已有，不用另找）：
- 风格图 `one_last_kiss.png` → `examples/Iris:fast_neural_style/images/style-images/`
- 校准图 90 张 COCO → `examples/Iris:fast_neural_style/images/calib/`
- 已训练的 3 个 `.model` → `examples/Iris:fast_neural_style/model/`

---

## C. 板端环境（Efinity）——当前阻塞

```bash
deploy/scripts/install-efinity.sh <efinity-<version>.tar.bz2> /mnt/mydata/efinity
```

Efinity Linux 版就是 tar.bz2 解压即用（官方 UG-EFN-INSTALL v4.1，无 root 步骤）。
但**软件下载和 license 都需要 Efinix 账号登录**：

- <https://www.efinixinc.com/support/> → 注册/登录 → Efinity Software Download（当前 **2026.1.132**）
- license 在同一页面申请，**免费**，绑定本机 MAC：`wlp3s0 = b8:1e:a4:6a:79:49`（别用 `docker0`）

目标版本必须与仓库对齐：Iris 用 `2026.1.132.4.5`，`tinyml` 仓库有 tag `efinity-v2026.1.132`。

---

## 本机现状对照（配之前）

| 项 | 状态 |
|---|---|
| Python | 3.12.3（`/usr/bin/python3`），无 conda（`/mnt/mydata/anaconda3` 已损坏） |
| torch / tensorflow | ❌ 都没有 |
| GPU | ❌ 无 `nvidia-smi` |
| Efinity / verilator / iverilog | ❌ 都没有 |
| 磁盘 | `/mnt/mydata` 203 GB 空闲；**`/` 与 `/tmp` 仅剩 ~13 GB，大文件别放这** |
