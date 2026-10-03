#!/usr/bin/env bash
# 把「用户随手给的一层路径」解析成两个明确的路径。
#
# 为什么需要这个
# --------------
# 这套脚本里有两个**含义相反**的路径参数，很容易搞混：
#   * train.py 用 torchvision 的 ImageFolder —— 语义是 <根>/<类别目录>/<图片>，
#     所以 `run_batch.sh --dataset` 要传 **图片目录的父目录**（如 .../coco）。
#   * make_subset.py 的 `--src` 要传 **图片所在目录本身**（如 .../coco/train2014）。
# 之前 web_quickstart.sh 把同一个值同时喂给这两个参数，于是：
#   传 .../coco          → 抽子集时报「里面没有图片」
#   传 .../coco/train2014 → 训练时报 ImageFolder 找不到子目录
# 两种写法必有一种炸。本文件把这一层判断收敛到一处。
#
# 用法（被 source，不要直接执行）：
#   source dataset_paths.sh
#   if resolve_dataset "<任意一层路径>"; then
#       echo "$DS_ROOT"     # → 给 run_batch.sh / bootstrap.sh 的 --dataset
#       echo "$DS_IMG_SRC"  # → 给 make_subset.py 的 --src
#   else
#       echo "$DS_ERR"      # → 人话错误信息
#   fi

# 数一个目录**直接**含多少张图片（不下钻）
count_imgs() {
    find "$1" -maxdepth 1 -type f \
        \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' \) 2>/dev/null | wc -l
}

# 解析路径。成功返回 0 并设置 DS_ROOT / DS_IMG_SRC；失败返回 1 并设置 DS_ERR。
resolve_dataset() {
    local p="${1%/}"
    DS_ROOT=""; DS_IMG_SRC=""; DS_ERR=""

    if [[ -z "$p" ]]; then
        DS_ERR="路径为空"
        return 1
    fi
    if [[ ! -d "$p" ]]; then
        DS_ERR="目录不存在: $p"
        return 1
    fi

    # 情形 A：这层自己就放着图片 → 它是类别目录，根是它的父目录
    if [[ "$(count_imgs "$p")" -gt 0 ]]; then
        DS_IMG_SRC="$p"
        DS_ROOT="$(dirname "$p")"
        return 0
    fi

    # 情形 B：这层是根，图片在它下面某层的子目录里
    local cands=() d
    for d in "$p"/*/; do
        [[ -d "$d" ]] || continue
        if [[ "$(count_imgs "${d%/}")" -gt 0 ]]; then
            cands+=("${d%/}")
        fi
    done

    if [[ ${#cands[@]} -eq 1 ]]; then
        DS_ROOT="$p"
        DS_IMG_SRC="${cands[0]}"
        return 0
    fi
    if [[ ${#cands[@]} -eq 0 ]]; then
        DS_ERR="里面既没有图片，也没有含图片的子目录: $p"
        return 1
    fi
    DS_ERR="里面有 ${#cands[@]} 个含图片的子目录（${cands[*]}）。ImageFolder 会把每个子目录当成一个类别，请只留一个（例如只放 train2014/）"
    return 1
}
