#!/usr/bin/env python3
"""从 COCO train2014 抽一个子集，做成 `train.py` 能吃的 ImageFolder 目录结构。

为什么需要
----------
`train.py` 用的是 `torchvision.datasets.ImageFolder`，它的语义是
`<dataset>/<类别目录>/<图片>` —— 所以 `--dataset` 必须指向**再往里一层才是图片**
的目录。COCO 解压出来正好是 `train2014/*.jpg`，所以 `--dataset` 要指向
`train2014` 的**父目录**。

另外 COCO 全量 80K 张 / 13 GB，第一次跑网格没必要全上：
先用 1 万张把 `style_weight` 的方向摸出来，再全量训练。

默认用**硬链接**（`os.link`），不额外占磁盘、不复制数据。
跨文件系统时会自动回退到符号链接。

用法
----
    python make_subset.py --src /root/gpufree-data/coco/train2014 \
                          --dst /root/gpufree-data/coco10k --num 10000
    # 之后： --dataset /root/gpufree-data/coco10k
"""

import argparse
import os
import random
import shutil
import sys


def link(src: str, dst: str) -> str:
    """优先硬链接 → 符号链接 → 复制。返回实际使用的方式。"""
    for how, fn in (("hardlink", os.link),
                    ("symlink", os.symlink),
                    ("copy", shutil.copy2)):
        try:
            fn(src, dst)
            return how
        except OSError:
            continue
    raise OSError(f"三种方式都失败了: {src}")


def main():
    p = argparse.ArgumentParser(description="COCO 子集抽取（ImageFolder 结构）")
    p.add_argument("--src", required=True, help="COCO train2014 图片目录")
    p.add_argument("--dst", required=True, help="输出目录（会创建 <dst>/train2014/）")
    p.add_argument("--num", type=int, default=10000, help="抽多少张（默认 1 万）")
    p.add_argument("--val-num", type=int, default=8,
                   help="另外留几张不进训练集，用于肉眼看风格化效果（默认 8）")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--class-name", default="train2014",
                   help="ImageFolder 的类别目录名（默认 train2014）")
    return p.parse_args()


if __name__ == "__main__":
    a = main()

    if not os.path.isdir(a.src):
        sys.exit(f"找不到源目录: {a.src}\n"
                 f"COCO 解压后应该是 train2014/*.jpg，请把 --src 指向 train2014")

    files = sorted(f for f in os.listdir(a.src)
                   if f.lower().endswith((".jpg", ".jpeg", ".png")))
    if not files:
        sys.exit(f"{a.src} 里没有图片。若里面还有一层子目录，检查一下是不是指错了层级。")
    if len(files) < a.num:
        print(f"⚠ 源目录只有 {len(files)} 张，少于请求的 {a.num} 张，按全部处理")

    random.seed(a.seed)
    picked = random.sample(files, min(a.num, len(files)))
    val = picked[:a.val_num]
    train = picked[a.val_num:]

    train_dir = os.path.join(a.dst, a.class_name)
    # 留出集必须放在 dataset 根目录**之外**：ImageFolder 会把根目录下每个子目录
    # 都当成一个类别，放在里面会被一起训进去，等于没留出。
    val_dir = a.dst.rstrip("/\\") + "_val"
    os.makedirs(train_dir, exist_ok=True)
    how = None
    for f in train:
        src = os.path.join(a.src, f)
        dst = os.path.join(train_dir, f)
        if not os.path.exists(dst):
            how = link(src, dst)
    if a.val_num:
        os.makedirs(val_dir, exist_ok=True)
        for f in val:
            dst = os.path.join(val_dir, f)
            if not os.path.exists(dst):
                link(os.path.join(a.src, f), dst)

    print(f"训练集 : {len(train)} 张 -> {train_dir}   （方式: {how}）")
    if a.val_num:
        print(f"留出   : {len(val)} 张 -> {val_dir}   （肉眼看风格化效果用）")
    print()
    print("下一步：")
    print(f"  python <deploy>/train/train.py train \\")
    print(f"      --dataset {a.dst} \\")
    print(f"      --style-image <examples>/fast_neural_style/images/style-images/one_last_kiss.png \\")
    print(f"      --save-model-dir <out> --channels 16 --blocks 3 --accel")
    print()
    print(f"注意：--dataset 传的是 {a.dst}（父目录），不是 {train_dir}")
