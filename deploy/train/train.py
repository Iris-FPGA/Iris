"""FlatFNS 训练/推理脚本。

由 `examples/Iris:fast_neural_style/neural_style/neural_style.py` 改写而来，
**只改网络与参数名，损失函数与训练循环保持原样**（VGG16 感知损失 + Gram 风格损失），
这样画质基线和调参经验都能沿用。

相对原脚本的改动
----------------
1. `TransformerNet(width=...)`      -> `FlatFNS(channels, blocks, kernel_size)`（见 flatfns_model.py）
2. `--width`                        -> `--channels` / `--blocks` / `--kernel-size`
   （原版 width 一次性缩放 32/64/128 三层通道；本网络单分辨率、单一通道数，
     没有对应的等比缩放语义，故换成显式参数）
3. 设备选择                         -> `_pick_device()`，兼容旧版 torch（2.5.1 等没有 torch.accelerator）
4. 保存模型时额外写 `train_config.json`（记录结构、超参、种子、参数量，对应
   《TinyML模型训练量化与Ti60F225部署计划.md》§6 P2 的记录要求）

用法（与队友的用法保持一致）
--------------------------
    python train.py train \
        --dataset /root/gpufree-data/coco \
        --style-image images/style-images/one_last_kiss.png \
        --save-model-dir /root/gpufree-data/runs/ol_kiss \
        --epochs 2 --channels 16 --blocks 3 --accel

    python train.py eval \
        --content-image images/content-images/amber.jpg \
        --model /root/gpufree-data/runs/ol_kiss/epoch_2_xxx.model \
        --output-image /tmp/out.jpg
"""

import argparse
import json
import os
import sys
import time

import numpy as np
import torch
from torch.optim import Adam
from torch.utils.data import DataLoader
from torchvision import datasets, transforms

import utils
from flatfns_model import FlatFNS
from vgg import Vgg16


def _pick_device(use_accel: bool) -> torch.device:
    """优先 CUDA，其次 MPS，最后 CPU；兼容没有 torch.accelerator 的旧版 torch。"""
    if not use_accel:
        return torch.device("cpu")
    if torch.cuda.is_available():
        return torch.device("cuda")
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        return torch.device("mps")
    print("警告：--accel 已指定但没有可用加速器，回退 CPU")
    return torch.device("cpu")


def _base_transform(image_size: int):
    return transforms.Compose([
        transforms.Resize(image_size),
        transforms.CenterCrop(image_size),
        transforms.ToTensor(),
        transforms.Lambda(lambda x: x.mul(255)),   # 输入域是 RGB 0~255（与原版一致）
    ])


def check_paths(args):
    try:
        if not os.path.exists(args.save_model_dir):
            os.makedirs(args.save_model_dir)
        if args.checkpoint_model_dir is not None and not os.path.exists(args.checkpoint_model_dir):
            os.makedirs(args.checkpoint_model_dir)
    except OSError as e:
        print(e)
        sys.exit(1)


def train(args):
    device = _pick_device(args.accel)
    print(f"Using device: {device}")

    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    train_dataset = datasets.ImageFolder(args.dataset, _base_transform(args.image_size))
    train_loader = DataLoader(train_dataset, batch_size=args.batch_size)

    transformer = FlatFNS(args.channels, args.blocks, args.kernel_size,
                          final_clamp=args.final_clamp).to(device)
    print(f"FlatFNS: channels={args.channels} blocks={args.blocks} k={args.kernel_size} "
          f"params={transformer.num_weight_params():,} MAC/px={transformer.macs_per_pixel():,}")

    optimizer = Adam(transformer.parameters(), args.lr)
    mse_loss = torch.nn.MSELoss()

    vgg = Vgg16(requires_grad=False).to(device)
    style_transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Lambda(lambda x: x.mul(255)),
    ])
    style = utils.load_image(args.style_image, size=args.style_size)
    style = style_transform(style)
    style = style.repeat(args.batch_size, 1, 1, 1).to(device)

    features_style = vgg(utils.normalize_batch(style))
    gram_style = [utils.gram_matrix(y) for y in features_style]

    for e in range(args.epochs):
        transformer.train()
        agg_content_loss = 0.
        agg_style_loss = 0.
        count = 0
        for batch_id, (x, _) in enumerate(train_loader):
            n_batch = len(x)
            count += n_batch
            optimizer.zero_grad()

            x = x.to(device)
            y = transformer(x)

            y = utils.normalize_batch(y)
            x = utils.normalize_batch(x)

            features_y = vgg(y)
            features_x = vgg(x)

            content_loss = args.content_weight * mse_loss(features_y.relu2_2, features_x.relu2_2)

            style_loss = 0.
            for ft_y, gm_s in zip(features_y, gram_style):
                gm_y = utils.gram_matrix(ft_y)
                style_loss += mse_loss(gm_y, gm_s[:n_batch, :, :])
            style_loss *= args.style_weight

            total_loss = content_loss + style_loss
            total_loss.backward()
            optimizer.step()

            agg_content_loss += content_loss.item()
            agg_style_loss += style_loss.item()

            if (batch_id + 1) % args.log_interval == 0:
                print("{}\tEpoch {}:\t[{}/{}]\tcontent: {:.6f}\tstyle: {:.6f}\ttotal: {:.6f}".format(
                    time.ctime(), e + 1, count, len(train_dataset),
                    agg_content_loss / (batch_id + 1),
                    agg_style_loss / (batch_id + 1),
                    (agg_content_loss + agg_style_loss) / (batch_id + 1)))

            if args.checkpoint_model_dir is not None and (batch_id + 1) % args.checkpoint_interval == 0:
                transformer.eval().cpu()
                torch.save(transformer.state_dict(), os.path.join(
                    args.checkpoint_model_dir, f"ckpt_epoch_{e}_batch_id_{batch_id + 1}.pth"))
                transformer.to(device).train()

    transformer.eval().cpu()
    timestamp = time.strftime("%Y-%m-%d_%H-%M-%S")
    # 命名沿用队友脚本的格式，方便现有工具链/文档继续引用
    name = f"epoch_{args.epochs}_{timestamp}_{args.content_weight}_{args.style_weight}.model"
    save_model_path = os.path.join(args.save_model_dir, name)
    torch.save(transformer.state_dict(), save_model_path)
    print("\nDone, trained model saved at", save_model_path)

    # 记录训练配置（《部署计划》§6 P2 要求：结构/超参/种子/参数量都要留档）
    cfg = {
        "arch": "FlatFNS",
        "channels": args.channels, "blocks": args.blocks,
        "kernel_size": args.kernel_size, "final_clamp": args.final_clamp,
        "input_domain": "RGB 0..255 (no ImageNet normalization)",
        "image_size": args.image_size, "epochs": args.epochs,
        "batch_size": args.batch_size, "lr": args.lr, "seed": args.seed,
        "content_weight": args.content_weight, "style_weight": args.style_weight,
        "style_image": os.path.abspath(args.style_image),
        "dataset": os.path.abspath(args.dataset),
        "num_weight_params": transformer.num_weight_params(),
        "macs_per_pixel": transformer.macs_per_pixel(),
        "model_file": os.path.abspath(save_model_path),
        "torch_version": torch.__version__,
    }
    with open(os.path.join(args.save_model_dir, "train_config.json"), "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print("训练配置已写入", os.path.join(args.save_model_dir, "train_config.json"))


def stylize(args):
    device = _pick_device(args.accel)
    print(f"Using device: {device}")

    content_image = utils.load_image(args.content_image, scale=args.content_scale)
    content_transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Lambda(lambda x: x.mul(255)),
    ])
    content_image = content_transform(content_image).unsqueeze(0).to(device)

    with torch.no_grad():
        model = FlatFNS(args.channels, args.blocks, args.kernel_size,
                        final_clamp=args.final_clamp)
        model.load_state_dict(torch.load(args.model, map_location="cpu"), strict=True)
        model.to(device).eval()
        output = model(content_image).cpu()

    utils.save_image(args.output_image, output[0])
    print("已保存", args.output_image)


def _add_arch_args(p):
    p.add_argument("--channels", type=int, default=16,
                   help="主干通道数 C（默认 16）。档位与算力见 flatfns_model.py 的 __main__ 表")
    p.add_argument("--blocks", type=int, default=3,
                   help="残差块个数 N（默认 3）")
    p.add_argument("--kernel-size", type=int, default=3,
                   help="卷积核尺寸（默认 3；原版首尾是 9，算力 ×9）")
    p.add_argument("--final-clamp", action="store_true",
                   help="输出端 clamp(0,255)。默认关，建议由下游按 .tflite 真实量化参数饱和")
    p.add_argument("--accel", action="store_true", help="使用加速设备（CUDA/MPS）")


def main():
    parser = argparse.ArgumentParser(description="FlatFNS (TinyML 算子合规版 fast-neural-style)")
    sub = parser.add_subparsers(title="subcommands", dest="subcommand")

    t = sub.add_parser("train", help="训练")
    t.add_argument("--epochs", type=int, default=2)
    t.add_argument("--batch-size", type=int, default=4)
    t.add_argument("--dataset", type=str, required=True,
                   help="训练集路径，须指向「内部还含一层子文件夹」的目录（ImageFolder 语义）")
    t.add_argument("--style-image", type=str, default="images/style-images/one_last_kiss.png")
    t.add_argument("--save-model-dir", type=str, required=True)
    t.add_argument("--checkpoint-model-dir", type=str, default=None)
    t.add_argument("--image-size", type=int, default=256)
    t.add_argument("--style-size", type=int, default=None)
    t.add_argument("--seed", type=int, default=42)
    t.add_argument("--content-weight", type=float, default=1e5)
    t.add_argument("--style-weight", type=float, default=1e10)
    t.add_argument("--lr", type=float, default=1e-3)
    t.add_argument("--log-interval", type=int, default=500)
    t.add_argument("--checkpoint-interval", type=int, default=2000)
    _add_arch_args(t)

    e = sub.add_parser("eval", help="用训练好的模型风格化一张图")
    e.add_argument("--content-image", type=str, required=True)
    e.add_argument("--content-scale", type=float, default=None)
    e.add_argument("--output-image", type=str, required=True)
    e.add_argument("--model", type=str, required=True)
    _add_arch_args(e)

    args = parser.parse_args()
    if args.subcommand is None:
        parser.error("请指定 train 或 eval")
    if args.subcommand == "train":
        check_paths(args)
        train(args)
    else:
        stylize(args)


if __name__ == "__main__":
    # 让脚本可以从任意目录直接跑（import utils / flatfns_model）
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
