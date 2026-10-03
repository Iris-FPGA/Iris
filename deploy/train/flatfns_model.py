"""FlatFNS —— 面向 Efinix TinyML 算子白名单改造的 Fast-Neural-Style 网络。

为什么需要这个网络
------------------
原始 `TransformerNet`（`examples/Iris:neural_style/transformer_net.py`）导出的
`.tflite` 实测含 7 类、93 个不在 TinyML 加速白名单内的算子：

    MIRROR_PAD ×16   <- ReflectionPad2d
    MEAN ×30 / SUB ×15 / SQRT ×15 / DIV ×15   <- InstanceNorm2d
    RESIZE_NEAREST_NEIGHBOR ×2                <- nearest×2 上采样

全部会掉回 RISC-V 软件执行。本网络把这三种结构**从架构上设计掉**：

| 原结构 | 本网络 | 消除的算子 |
|---|---|---|
| `ReflectionPad2d` + Conv | `Conv2d(padding=k//2)` 零填充 | `MIRROR_PAD` |
| `InstanceNorm2d(affine=True)` | `BatchNorm2d`（导出前折叠进卷积） | `MEAN/SUB/SQRT/DIV` |
| `nearest×2` + Conv（deconv 块） | **不做图内上下采样**，整网单分辨率 | `RESIZE_NEAREST_NEIGHBOR` |
| 独立 `nn.ReLU` 层 | ReLU 紧跟 Conv+BN，被 TFLite 融合进 `CONV_2D` | 独立 `RELU` |

导出 + 全整数量化后，图中只应剩 **`CONV_2D` + `ADD`**（都是白名单算子）。

白名单来源
----------
- `tinyml/tools/tinyml_generator/README.md`（Supported layers for hardware acceleration）
- `tinyml/**/src/platform/tinyml/ops/`（只有 conv/depthwise/add/mul/lr/maxmin/reshape/fully_connected 八个驱动）
"""

import copy

import torch
import torch.nn as nn


def conv_bn(cin: int, cout: int, k: int = 3, stride: int = 1) -> nn.Sequential:
    """Conv2d(零填充 SAME) + BatchNorm2d。

    用零填充而不是反射填充：`padding=k//2` 会被 TFLite 的 `CONV_2D` 以
    `SAME` padding 形式吸收，图里**不产生任何额外算子**；反射填充则会生成
    独立的 `MIRROR_PAD`。

    BatchNorm 只是训练期的存在，导出前用 `fuse_bn()` 折叠进卷积，
    因此也不会留下 `MEAN/SQRT/SUB/DIV` 链。
    """
    return nn.Sequential(
        nn.Conv2d(cin, cout, k, stride, padding=k // 2, bias=False),
        nn.BatchNorm2d(cout),
    )


class ResidualBlock(nn.Module):
    """标准 Johnson 残差块：Conv-BN-ReLU / Conv-BN / +identity。

    这里**没有**在相加之后加激活，与原始 `transformer_net.py` 一致；
    相加本身映射到白名单里的 `ADD`，且 `add_drv()` 支持两个输入不同的
    scale/zero_point，所以残差连接是安全的。
    """

    def __init__(self, channels: int, k: int = 3):
        super().__init__()
        self.conv1 = conv_bn(channels, channels, k)
        self.relu = nn.ReLU(inplace=False)
        self.conv2 = conv_bn(channels, channels, k)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x + self.conv2(self.relu(self.conv1(x)))


class FlatFNS(nn.Module):
    """单分辨率全卷积风格迁移网络（可直接换掉 `TransformerNet`）。

    输入/输出都是 RGB 0~255 域、NHWC 由转换器负责转置；
    网络是**全卷积**的，任意 `H×W` 都能跑（训练 256×256，部署用低分辨率 + 显示侧放大）。

    参数：
        channels:    主干通道数 C
        blocks:      残差块个数 N
        kernel_size: 卷积核（默认 3；原版首尾是 9×9，可传 9 换取更大感受野，算力 ×9）
        final_clamp: 是否在输出端 clamp(0,255)。默认关：
                     建议改由下游按 `.tflite` 的真实量化参数饱和（见 README）。
                     打开时会额外产生 `MINIMUM`（在白名单内），
                     其中 min=0 会融合进 `CONV_2D`。
    """

    def __init__(self, channels: int = 16, blocks: int = 3,
                 kernel_size: int = 3, final_clamp: bool = False):
        super().__init__()
        self.channels = channels
        self.blocks = blocks
        self.kernel_size = kernel_size
        self.final_clamp = final_clamp

        self.head = conv_bn(3, channels, kernel_size)
        self.head_relu = nn.ReLU(inplace=False)
        self.res = nn.Sequential(*[ResidualBlock(channels, kernel_size) for _ in range(blocks)])
        # 尾层：无 BN、无激活，直接出 3 通道 RGB
        self.tail = nn.Conv2d(channels, 3, kernel_size, 1, padding=kernel_size // 2, bias=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self.head_relu(self.head(x))
        out = self.res(out)
        out = self.tail(out)
        if self.final_clamp:
            # clamp_min=0 会融合进 CONV_2D；上限 255 留下一个 MINIMUM 算子
            out = torch.clamp(out, 0.0, 255.0)
        return out

    # ---- 算力 / 体积（用于按 Ti60 资源挑档位）----
    def macs_per_pixel(self) -> int:
        """每输出像素的乘累加次数。

        对 k×k 卷积而言，它恰好等于**卷积权重个数**（不含 bias、不含 BN）：
        每个输出通道每像素要做 `Cin * k²` 次 MAC，共 Cout 个输出通道。
        """
        c, n, k2 = self.channels, self.blocks, self.kernel_size ** 2
        return k2 * (3 * c + 2 * n * c * c + 3 * c)

    def num_weight_params(self) -> int:
        """卷积权重个数（= MAC/px）。"""
        return sum(p.numel() for m in self.modules() if isinstance(m, nn.Conv2d)
                   for p in [m.weight])

    def num_params(self) -> int:
        """全部可训练参数（含 BN 仿射与 bias）；BN 折叠后这部分会并进卷积 bias。"""
        return sum(p.numel() for p in self.parameters())


def _fuse_bn_inplace(model: nn.Module) -> None:
    """就地递归折叠（不拷贝）。"""
    from torch.nn.utils.fusion import fuse_conv_bn_eval

    for name, child in list(model.named_children()):
        if (isinstance(child, nn.Sequential) and len(child) == 2
                and isinstance(child[0], nn.Conv2d) and isinstance(child[1], nn.BatchNorm2d)):
            setattr(model, name, fuse_conv_bn_eval(child[0], child[1]))
        elif len(list(child.children())) > 0:
            _fuse_bn_inplace(child)


def fuse_bn(model: nn.Module) -> nn.Module:
    """把 `Sequential(Conv2d, BatchNorm2d)` 折叠成带 bias 的 `Conv2d`。

    折叠后图里不再有 BatchNorm 节点 —— 这是消除 `InstanceNorm` 那一串
    `MEAN/SQRT/SUB/DIV` 的关键一步（BN 能折叠是因为它是逐通道仿射变换，
    InstanceNorm 是逐图逐通道统计，无法离线折叠）。

    返回新模型，不改动入参。
    """
    model = copy.deepcopy(model).eval()
    _fuse_bn_inplace(model)
    return model


def build_model(channels: int = 16, blocks: int = 3, kernel_size: int = 3,
                final_clamp: bool = False, weights: str | None = None) -> FlatFNS:
    """按档位建网；`weights` 给定时加载 state_dict。"""
    net = FlatFNS(channels, blocks, kernel_size, final_clamp)
    if weights:
        sd = torch.load(weights, map_location="cpu")
        if isinstance(sd, dict) and "state_dict" in sd:
            sd = sd["state_dict"]
        net.load_state_dict(sd, strict=True)
    return net


if __name__ == "__main__":
    # 档位速查：python deploy/train/flatfns_model.py
    print(f"{'C':>3} {'N':>2} {'MAC/px=参数量':>14} {'INT8 权重':>10} "
          f"{'96x96':>9} {'128x128':>9} {'160x120':>9}  (@15fps, 128x128)")
    for c in (16, 24, 32):
        for n in (3, 4, 5):
            m = FlatFNS(c, n)
            mpp = m.macs_per_pixel()
            w = m.num_weight_params()
            assert mpp == w, f"MAC/px({mpp}) 应等于卷积权重个数({w})"
            f96 = mpp * 96 * 96 / 1e6
            f128 = mpp * 128 * 128 / 1e6
            f160 = mpp * 160 * 120 / 1e6
            print(f"{c:>3} {n:>2} {mpp:>14,} {w/1024:>9.1f}K "
                  f"{f96:>7.0f}MM {f128:>7.0f}MM {f160:>7.0f}MM "
                  f"{f128*15/1000:>10.1f} GMAC/s")
