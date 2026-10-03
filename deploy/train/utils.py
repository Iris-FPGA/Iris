# 来源: FinResect/examples @ Iris 分支 fast_neural_style/neural_style/utils.py
# 原样复制（pytorch/examples 的 BSD 许可代码），供 deploy/train 自包含使用。
#
# 改动：`Image.ANTIALIAS` 在 Pillow 10 中已被移除，原代码会直接抛
#       AttributeError: module 'PIL.Image' has no attribute 'ANTIALIAS'。
#       这里换成 `Image.Resampling.LANCZOS` 并保留对老 Pillow 的兼容。
import torch
from PIL import Image

# Pillow >= 9.1 用 Image.Resampling.LANCZOS；更老的版本只有 Image.ANTIALIAS
_RESAMPLE = getattr(getattr(Image, "Resampling", Image), "LANCZOS", None) \
    or getattr(Image, "ANTIALIAS", None)


def load_image(filename, size=None, scale=None):
    img = Image.open(filename).convert('RGB')
    if size is not None:
        img = img.resize((size, size), _RESAMPLE)
    elif scale is not None:
        img = img.resize((int(img.size[0] / scale), int(img.size[1] / scale)), _RESAMPLE)
    return img


def save_image(filename, data):
    img = data.clone().clamp(0, 255).numpy()
    img = img.transpose(1, 2, 0).astype("uint8")
    img = Image.fromarray(img)
    img.save(filename)


def gram_matrix(y):
    (b, ch, h, w) = y.size()
    features = y.view(b, ch, w * h)
    features_t = features.transpose(1, 2)
    gram = features.bmm(features_t) / (ch * h * w)
    return gram


def normalize_batch(batch):
    # normalize using imagenet mean and std
    #
    # 改动：原代码用 `batch.div_(255.0)` 做**原地**除法。因为训练循环里
    # `x = utils.normalize_batch(x)` 发生在 `y = transformer(x)` 之后，
    # 原地修改会把 autograd 为卷积反向传播保存的输入张量就地改掉，直接报：
    #   RuntimeError: one of the variables needed for gradient computation has been
    #   modified by an inplace operation ... is at version 1; expected version 0
    # 改成非原地运算，语义完全等价，且不再污染调用方的张量。
    mean = batch.new_tensor([0.485, 0.456, 0.406]).view(-1, 1, 1)
    std = batch.new_tensor([0.229, 0.224, 0.225]).view(-1, 1, 1)
    batch = batch / 255.0
    return (batch - mean) / std
