# 云上跑批（算力自由 GPU）

对 `configs.tsv` 里每个配置跑完整链路：

```
训练 → 导出 ONNX(G1 门禁) → INT8 量化 → 算子门禁(G2/G3) → 精度对比(G4) → 风格化样图
```

结果汇总到 `results.csv`。**单个配置失败不会中断整批。**

---

## 一、三步走

> **第一次上云请看 [`运行手册.md`](运行手册.md)** —— 那是按算力自由（gpufree.cn）
> 平台写的逐步操作清单，包含"无卡模式开机先做完准备工作"这类省钱的顺序。

### 1. 本机打包（32 KB）

```bash
deploy/cloud/pack.sh          # -> deploy/cloud/deploy_code.tar.gz
```

只打 `train/ quant/ verify/ env/ cloud/`，**不含** `.venv`(3.7G) / `.torch`(528M) / `out/` / 数据集。

### 2. 传到云主机

```bash
scp deploy/cloud/deploy_code.tar.gz  <user>@<host>:/root/
ssh <user>@<host>
mkdir -p /root/gpufree-data && cd /root/gpufree-data
tar -xzf /root/deploy_code.tar.gz          # 解开是 train/ quant/ verify/ env/ cloud/
```

> `/root/gpufree-data/` 是持久化目录 —— 队友的 `examples/Iris:fast_neural_style/script/para.py:3`
> 里写死的就是这个路径，说明云主机上代码放这里实例重启不丢。

### 3. 自检 + 跑批

```bash
# 先自检（装缺的依赖、拉风格图与校准图、检查数据集、生成 env.sh）
deploy/cloud/bootstrap.sh --dataset /root/gpufree-data/coco/train2014

# 再冒烟：1 个配置、1 epoch、64×64、batch 2 —— 只为验证链路通不通
deploy/cloud/run_batch.sh --smoke

# 通了再跑完整网格
deploy/cloud/run_batch.sh
```

> `bootstrap.sh` 默认**不装**转换栈（TF/onnx/onnx2tf）——转换建议在本机做
> （`deploy/.venv` 已配好，见 `deploy/env/README.md`）。
> 若确实要在云上量化，加 `--with-convert`；它装的是 **`tensorflow-cpu`**，
> 刻意不装 GPU 版，避免和云镜像里的 CUDA torch 抢 cuDNN。

### 4. （可选）先抽子集再全量

COCO 全量 80K 张 / 13 GB，第一次跑网格没必要全上。用 `make_subset.py`
抽 1 万张摸清 `style_weight` 方向，再全量训练：

```bash
python deploy/cloud/make_subset.py \
    --src /root/gpufree-data/coco/train2014 \
    --dst /root/gpufree-data/coco10k --num 10000
```

默认用**硬链接**，不额外占磁盘。注意之后 `--dataset` 传 `/root/gpufree-data/coco10k`
（父目录），不是 `.../coco10k/train2014`。留出的验证集放在 `<dst>_val`，
**在 dataset 根目录之外**——放里面会被 `ImageFolder` 当成第二个类别训进去。

---

## 二、数据集

COCO 2014 train（13 GB）：<https://cocodataset.org/#download>

解压后若是 `train2014/xxx.jpg`，**`--dataset` 要指向它的父目录**（`ImageFolder` 语义：再往里一层才是图片）：

```
/root/gpufree-data/coco/
└── train2014/          <- 图片都在这一层
    ├── COCO_train2014_000000000009.jpg
    └── ...
```
→ `--dataset /root/gpufree-data/coco/train2014`（bootstrap 会自动检查这层结构并在不对时告警）

---

## 三、常用参数

```bash
run_batch.sh --smoke                  # 1 个配置、1 epoch、64×64、batch 2
run_batch.sh --only c16b3             # 只跑名字匹配的（正则）
run_batch.sh --limit 2                # 只跑前 2 行
run_batch.sh --force                  # 重跑已完成的
run_batch.sh --no-accel               # 强制 CPU（调试用）
run_batch.sh --size 160               # 导出/量化的部署分辨率（默认 128）
run_batch.sh --out /root/gpufree-data/runs/batch1
run_batch.sh --configs my_grid.tsv    # 换实验矩阵
```

**断点续跑**：每个配置完成后会在 `runs/<name>/STATUS` 写状态；重跑时自动跳过，
加 `--force` 才重跑。

---

## 四、产出

```
<out>/
├── results.csv                    # 汇总表（每个配置一行）
├── logs/<name>.log                # 6 个步骤的完整日志
├── runs/<name>/
│   ├── epoch_*.model              # 训练权重
│   ├── train_config.json          # 结构/超参/种子/参数量（《部署计划》§6 P2 要求）
│   ├── STATUS / SECONDS
├── <name>.onnx                    # ONNX
├── <name>_int8.tflite             # ← 交付物
├── <name>_int8_float32.tflite     # FP32 参考（精度对比用）
├── <name>_compliance.md           # 算子合规报告
├── <name>.gate.json               # 门禁结果（机器可读）
├── <name>.equiv.json              # PSNR/SSIM（机器可读）
└── <name>_stylized.jpg            # 风格化样图（肉眼看效果）
```

`results.csv` 列：

```
name, channels, blocks, params, macs_per_px, epochs, seconds,
non_whitelisted_ops, gate, psnr_quant_db, ssim_quant,
psnr_e2e_db, ssim_e2e, tflite_kb, status
```

---

## 五、实验矩阵怎么定（`configs.tsv`）

现在这一版是 **6 个配置的起步网格**，两个目的：

1. **重扫 `style_weight`**（`1e10 / 3e9 / 3e10`）
   —— `InstanceNorm` 换成 `BatchNorm` 之后**风格强度一定会变**。队友原来的 `1e10`
   是配 IN 扫出来的，直接沿用大概率偏弱或偏强，这个必须重扫，不能省。
2. **容量升档**（`C=16 N=3/4`、`C=24 N=3`、`C=32 N=3`）
   —— 先看画质能不能接受，再拿 `macs_per_px` 对照 Ti60 的算力预算选档。

档位算力表：`python deploy/train/flatfns_model.py`

| C | N | MAC/px | INT8 权重 | 128×128 MMAC/帧 | @15fps |
|---|---|---|---|---|---|
| 16 | 3 | 14,688 | 14.3 KB | 241 | 3.6 GMAC/s |
| 16 | 4 | 19,296 | 18.8 KB | 316 | 4.7 |
| 24 | 3 | 32,400 | 31.6 KB | 531 | 8.0 |
| 32 | 3 | 57,024 | 55.7 KB | 934 | 14.0 |

> 记住：**参数量 ≡ 每像素 MAC 数**（3×3 权重不复用），所有档位 INT8 都 <100 KB,
> 所以 L5c 的 500 KB 约束不是瓶颈，**算力才是**。加速器能到多少 GMAC/s
> 要用 Efinity TinyML Generator 的 Resource Estimator + 板端 profiler 实测（计划里的 G5）。

---

## 六、开销预估

* 单配置全链路（不含训练）本机 CPU 实测约 **22 秒**（见 `../out/batch_test/`，冒烟跑通产物）。
* 训练是大头：COCO 80K 张 / 2 epoch / `C=16 N=3` / 256×256 / batch 4，
  单卡 4090 大约数小时量级 —— 以云上实测为准，先跑 `--smoke` 拿到单 epoch 时间再乘。

---

## 七、已在本机验证过的部分

`run_batch.sh --smoke` **已在本机完整跑通**（CPU，22 秒）：6 个步骤全执行、
门禁通过（`CONV_2D×8, ADD×3`，非白名单 0 个）、`results.csv` 正常生成。
产物在 `deploy/out/batch_test/`，可以对照确认云上输出格式一致。
