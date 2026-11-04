# -*- coding: utf-8 -*-
"""
Generate the complete contest technical report for Iris according to the template.
"""
import os
import shutil
from pathlib import Path
import docx
from docx.shared import Pt, Inches, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
from docx.oxml import OxmlElement
from docx.oxml.ns import qn


def set_cell_background(cell, fill_color):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), fill_color)
    tcPr.append(shd)


def set_cell_margins(cell, top=100, bottom=100, left=150, right=150):
    tcPr = cell._tc.get_or_add_tcPr()
    tcMar = OxmlElement('w:tcMar')
    for m, val in [('top', top), ('bottom', bottom), ('left', left), ('right', right)]:
        node = OxmlElement(f'w:{m}')
        node.set(qn('w:w'), str(val))
        node.set(qn('w:type'), 'dxa')
        tcMar.append(node)
    tcPr.append(tcMar)


def create_report():
    template_path = '技术文档模板.docx'
    output_path = 'Iris设计报告.docx'

    # Start fresh from the template file structure
    doc = docx.Document(template_path)

    # Clear existing template placeholder paragraphs
    for p in list(doc.paragraphs):
        p._p.getparent().remove(p._p)
    for t in list(doc.tables):
        t._element.getparent().remove(t._element)

    sec = doc.sections[0]
    sec.top_margin = Inches(1.0)
    sec.bottom_margin = Inches(1.0)
    sec.left_margin = Inches(1.1)
    sec.right_margin = Inches(1.1)

    # Helper functions
    def add_title(text):
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(12)
        p.paragraph_format.space_after = Pt(18)
        run = p.add_run(text)
        run.font.name = '黑体'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '黑体')
        run.font.size = Pt(22)
        run.font.bold = True
        return p

    def add_subtitle(text):
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_after = Pt(18)
        run = p.add_run(text)
        run.font.name = '宋体'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '宋体')
        run.font.size = Pt(11)
        run.font.color.rgb = RGBColor(128, 128, 128)
        return p

    def add_heading1(text):
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(16)
        p.paragraph_format.space_after = Pt(8)
        p.paragraph_format.keep_with_next = True
        run = p.add_run(text)
        run.font.name = '黑体'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '黑体')
        run.font.size = Pt(15)
        run.font.bold = True
        return p

    def add_heading2(text):
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(10)
        p.paragraph_format.space_after = Pt(4)
        p.paragraph_format.keep_with_next = True
        run = p.add_run(text)
        run.font.name = '黑体'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '黑体')
        run.font.size = Pt(13)
        run.font.bold = True
        return p

    def add_heading3(text):
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(6)
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.keep_with_next = True
        run = p.add_run(text)
        run.font.name = '宋体'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '宋体')
        run.font.size = Pt(11.5)
        run.font.bold = True
        return p

    def add_body(text, bold_prefix="", indent=True):
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(4)
        p.paragraph_format.line_spacing = 1.25
        if indent:
            p.paragraph_format.first_line_indent = Pt(24)
        if bold_prefix:
            r_pre = p.add_run(bold_prefix)
            r_pre.font.name = '宋体'
            r_pre._element.rPr.rFonts.set(qn('w:eastAsia'), '宋体')
            r_pre.font.size = Pt(10.5)
            r_pre.font.bold = True
        run = p.add_run(text)
        run.font.name = '宋体'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '宋体')
        run.font.size = Pt(10.5)
        return p

    def add_caption(text):
        p = doc.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(3)
        p.paragraph_format.space_after = Pt(8)
        run = p.add_run(text)
        run.font.name = '宋体'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '宋体')
        run.font.size = Pt(9.5)
        run.font.bold = True
        return p

    def add_image_if_exists(img_path, caption, width=Inches(5.5)):
        if os.path.exists(img_path):
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(8)
            p.paragraph_format.space_after = Pt(2)
            run = p.add_run()
            run.add_picture(img_path, width=width)
            add_caption(caption)
        else:
            print(f"Warning: image {img_path} not found")

    def add_side_by_side_images(img1, img2, caption, width=Inches(2.85)):
        if os.path.exists(img1) and os.path.exists(img2):
            p = doc.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(8)
            p.paragraph_format.space_after = Pt(2)
            r1 = p.add_run()
            r1.add_picture(img1, width=width)
            p.add_run("   ")
            r2 = p.add_run()
            r2.add_picture(img2, width=width)
            add_caption(caption)

    # 1. Title & Abstract
    add_title("Iris：基于易灵思 Ti60 FPGA 的边缘 AI 实时风格化视频渲染系统")
    add_subtitle("（本报告为匿名评审版本，正文中不包含参赛队员、指导教师及高校名称等个人信息）")

    add_heading1("摘  要")
    abstract_text = (
        "随着边缘计算与人工智能生成内容（AIGC）的发展，在低功耗嵌入式终端上实时完成视频艺术风格化渲染具有重要的实用价值。针对传统风格迁移网络计算量大、外部访存开销高、难以在资源受限边缘设备上兼顾分辨率与帧率的问题，本项目以易灵思 Titanium Ti60F225 FPGA 芯片与开源 Sapphire RISC-V 异构软核为平台，面向 2026 年全国大学生嵌入式芯片与系统设计竞赛「实时绘画」赛题，设计并实现了一套软硬件协同的实时风格化视频渲染系统——Iris。\n"
        "系统在算法与硬件设计上完成了三项核心工作：第一，实现「720p@30fps 等比空间映射与脉动行流水加速」，通过整数相位累加器构建 16:9 视域 ROI 采样逻辑，并定制片上权重驻留的 8×8 脉动阵列加速器，单帧推理用时约 31.27 ms，实现原生 30.05 FPS 实时推理；第二，设计「基于 VSync 同步的硬件帧间线性插值模块」，利用片上行缓存在相邻两帧推理结果之间按显示子帧周期执行移位加权混合，缓解 30 FPS 推理流在 1080p@60Hz 显示器上的帧间跳变感，支持 60 FPS 平滑过渡输出；第三，实现位流与双风格固件（Anime Sketch 动漫线稿 ⇄ Monet 莫奈油画）一体化 SPI Flash 固化与自搬移引导，支持上电数秒内脱机冷启动运行。\n"
        "实板测试表明，系统各时钟域时序收敛闭合，原生风格化推理稳定达到 30.05 FPS，开启帧间插值后支持 1080p @ 60 FPS 显示输出，显存欠载计数与读错误计数全程为零，按键动态切换风格延迟低于 60 ms，兼具良好的实时性、稳定性与交互体验。"
    )
    add_body(abstract_text, indent=True)
    add_body("FPGA；RISC-V 异构协同；神经风格迁移；行流水加速；帧间线性插值；脱机自启动", bold_prefix="关键词：", indent=False)

    # 第一部分 作品概述
    add_heading1("第一部分  作品概述")

    add_heading2("1.1 功能与特性")
    feat_text = (
        "Iris 是面向边缘场景的低延迟实时风格化视频渲染系统。系统通过四通道 MIPI CSI-2 接入 SC431HAI 摄像头，经 FPGA 硬件 ISP 完成 RAW10 解包、去马赛克、白平衡与等比采样，驱动片上 8×8 脉动阵列执行 INT8 卷积风格迁移，通过 HDMI 以 1080p@60Hz 输出画面并叠加帧率状态。\n"
        "主要特性包括：（1）多风格在线切换：片上集成动漫线稿（Anime Sketch）与莫奈油画（Monet）两套网络权重，支持按键 SW0 在 60 ms 内免重启无损切换，不丢帧、不黑屏；（2）三种显示模式：支持 SW1 循环切换左右分屏对比、全屏原画与全屏风格画；（3）帧间线性插值开关：支持 SW2 在 30 FPS 原生直出与 60 FPS 线性过渡输出间切换；（4）脱机自启动：位流与双模型固件固化于 8 MB SPI Flash，单线供电即可独立运行。"
    )
    add_body(feat_text)
    add_image_if_exists('/tmp/report_media/image2.png', "图1-1  Iris 实时风格化视频渲染系统总体框图")

    add_heading2("1.2 应用领域")
    app_text = (
        "作品面向边缘实时视频滤镜、互动展示与嵌入式视觉教学等应用场景：\n"
        "（1）数字艺术展陈与文旅互动：在展馆、科技馆或校园开放日展台，将现场观众与实景实时转换为线稿或油画风格并分屏对照。单板全嵌入式形态无需外接高功耗 PC 主机或依赖云端 GPU，插电即用、部署便捷。\n"
        "（2）低功耗便携直播与视频前处理：作为便携式硬件滤镜终端，在本地实时输出风格化视频信号，整板运行功耗低于 3 W，适合移动展示与户外创客场景。\n"
        "（3）本地视觉脱敏看护：在室内看护等注重隐私的场景中，在采集源头直接输出线条轮廓画面，既保留人体姿态动作轮廓，又避免原始人脸与环境细节外泄。\n"
        "（4）嵌入式异构计算教学示范：完整涵盖 MIPI D-PHY 采集、DDR3 多端口仲裁、RISC-V 软核驱动、INT8 卷积加速及 Flash 引导，适合作为高校 FPGA 与边缘 AI 软硬件协同教学案例。"
    )
    add_body(app_text)
    add_image_if_exists('/tmp/report_media/image11.jpg', "图1-2  手持终端实屏分屏风格化渲染效果")

    add_heading2("1.3 主要技术特点")
    tech_text = (
        "（1）RISC-V + FPGA 异构分工：Sapphire RISC-V 软核负责模型参数加载、三缓冲租约调度、按键响应与反量化参数配置；FPGA 可编程逻辑承担高速视频流处理、并行乘加运算与 HDMI 扫描输出，软硬件职责清晰。\n"
        "（2）片上权重驻留与行流水传递：将量化后的卷积权重驻留于片上 BRAM，层间特征通过行缓存（Line Buffer）流式衔接，避免中间特征图反复读写外部 DDR3，显著降低外部访存带宽占用。\n"
        "（3）720p@30fps 等比视域采样：采用整数 DDA 相位累加采样器，在 16:9 全屏与分屏对比模式下保持几何纵横比一致，单帧推理耗时稳定在 31.27 ms。\n"
        "（4）轻量级帧间线性插值与行内平滑放大：针对 30 FPS 推理更新与 60 Hz 显示刷新的速率差异，采用无乘法器移位加法对相邻两帧风格结果做线性过渡，并配合水平四相位线性插值放大减轻锯齿感。"
    )
    add_body(tech_text)

    add_heading2("1.4 主要性能指标")
    add_body("系统经板级连续运行测试，各项主要性能指标实测结果如下表所示：", indent=False)

    table_data = [
        ["指标项目", "竞赛基础/高阶要求", "Iris 实测指标", "达成情况"],
        ["摄像头输入", "MIPI CSI-2 SC431HAI 接口", "1920×1080 @ 60 FPS RAW10", "达标"],
        ["处理与输出分辨率", "640×480 @ 15 FPS（高阶 720p@30）", "720p 视域采样 / 1080p HDMI 输出", "达标"],
        ["原生 AI 推理帧率", "≥ 15 FPS（基础）/ ≥ 30 FPS（高阶）", "原生 30.05 FPS（单帧 31.27 ms）", "达标"],
        ["显示刷新与插帧", "≥ 720p@60fps 或 1080p@30fps", "1080p @ 60 Hz（支持帧间线性插值）", "达标"],
        ["多风格实时切换", "预置 ≥ 2 种风格，延迟 < 100ms", "线稿 / 莫奈 双风格，切换 < 60 ms", "达标"],
        ["内存欠载/读写错误", "画面稳定不丢帧、不撕裂", "Underflow=0, ReadErr=0", "零错误"],
        ["脱机自启动", "鼓励提高系统集成度", "8MB SPI Flash 脱机冷启动（<3s）", "已实现"],
        ["时序收敛裕量", "满足工作时钟时序约束", "Setup: +0.162 ns, Hold: +0.026 ns", "已收敛"]
    ]
    t = doc.add_table(rows=len(table_data), cols=4)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for r_idx, row in enumerate(table_data):
        for c_idx, val in enumerate(row):
            cell = t.cell(r_idx, c_idx)
            cell.text = val
            p = cell.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            set_cell_margins(cell, top=60, bottom=60, left=80, right=80)
            if r_idx == 0:
                set_cell_background(cell, "EAECEE")
                p.runs[0].font.bold = True
                p.runs[0].font.name = '黑体'
                p.runs[0].font.size = Pt(9.5)
            else:
                p.runs[0].font.name = '宋体'
                p.runs[0].font.size = Pt(9.0)
    add_caption("表1-1  系统主要性能指标与实测对照表")

    add_heading2("1.5 主要创新点")
    innovations = [
        ("（1）等比空间采样与脉动行流水加速：",
         "采用整数 DDA 等比提取 720p 视域，结合片上权重驻留行流水与 8×8 INT8 脉动阵列，单帧推理压缩至 31.27 ms（30.05 FPS）。"),
        ("（2）低开销硬件帧间线性插值显示：",
         "跟踪 VSync 提交周期，通过片上行缓存与移位加权电路对相邻两帧风格结果做线性过渡，减轻 30 FPS 直出的帧间跳变。"),
        ("（3）双模型自搬移 Flash 脱机启动：",
         "将位流与双风格固件统一存入 8 MB SPI Flash，结合 FNV-1a 校验与双张量池预分配，实现上电自启与 <60 ms 风格切换。")
    ]
    for title, desc in innovations:
        add_body(desc, bold_prefix=title, indent=True)

    add_heading2("1.6 设计流程")
    flow_text = (
        "（1）模型蒸馏与量化：以 Fast Neural Style 为教师网络，经通道裁剪与知识蒸馏将模型压缩至 500 KB 内，完成 BN 折叠与 INT8 定点量化；（2）定点对齐仿真：对比 Python/TFLite 整数参考与 RTL 逐层输出；（3）硬件逻辑开发：实现 MIPI 采集、DDA 采样、8×8 脉动阵列、帧间线性插值与 HDMI OSD；（4）时序收敛与板级固化：完成多时钟域 SDC 约束、长测验证与 SPI Flash 脱机启动。"
    )
    add_body(flow_text)
    add_image_if_exists('/tmp/report_media/image5.png', "图1-3  模型部署与软硬件协同验证流程")

    # 第二部分 系统组成及功能说明
    add_heading1("第二部分  系统组成及功能说明")

    add_heading2("2.1 整体介绍")
    arch_text = (
        "系统由四大核心子系统构成：视频采集预处理子系统、神经网络硬件加速子系统、视频合成与高清显示子系统，以及 Sapphire RISC-V 协同控制子系统，整体结构如图 2-1 所示。\n"
        "各子系统之间通过三组独立缓冲区与状态握手解耦运行：（1）视频数据由 SC431HAI 摄像头经四通道 MIPI CSI-2 输入，在 FPGA 内部经 D-PHY 硬核与 CSI-2 RX 解包后写入原生帧缓存，再经去马赛克、滤波及白平衡校正生成 1080p RGB 视频流；（2）RGB 视频流分为两路：一路直接送往显示端作为原图画面源；另一路经张量预处理模块按视域等比下采样并量化写入 DDR3 输入三缓冲区；（3）RISC-V 软核调度硬件加速器通过 AXI4 总线读取输入张量，由 8×8 脉动阵列与行流水单元完成多层卷积计算并写回输出三缓冲区；（4）显示流水线依据当前视图模式读取输出缓冲区，经硬件反量化、可选帧间线性插值及水平线性放大后与原图画面合成 1080p @ 60 Hz 信号输出至 HDMI 显示器。"
    )
    add_body(arch_text)
    add_image_if_exists('/tmp/report_media/image2.png', "图2-1  Iris 系统组成与数据流框图")

    add_heading2("2.2 硬件系统介绍")
    add_heading3("2.2.1 硬件整体介绍")
    hw_text = (
        "硬件主控采用易灵思 Ti60F225_DemoBoard_v4 开发板（核心芯片 Ti60F225I3），片上具备 60,800 个逻辑单元（XLR）、160 个 DSP 块、256 个片上 RAM 块以及高速 MIPI D-PHY 硬核。板载 16 位 256 MB DDR3 存储器（控制器核心时钟 200 MHz，双倍数据率接口时钟 400 MHz，内部转换至 128 位 AXI4 总线）与 8 MB SPI NOR Flash，外接 SC431HAI 摄像头模组与 1080p HDMI 显示屏。"
    )
    add_body(hw_text)

    add_heading3("2.2.2 机械设计介绍")
    mech_text = (
        "为便于现场交互展示与手持拍摄，系统设计了模块化 3D 打印一体式结构件，包含显示屏防护边框、中央握持连接手柄以及主板与摄像头防护盒三部分（见图 2-2）。主板与 SC431HAI 摄像头模组通过螺柱稳固安装于右侧防护盒内，按键、Type-C 接口与 HDMI 接口均留有开孔；中央手柄将处理盒与左侧便携 HDMI 显示屏刚性连接，减小手持移动时对 MIPI 排线的拉扯干扰。"
    )
    add_body(mech_text)
    add_image_if_exists('/tmp/report_media/image8.jpg', "图2-2  系统整体装配结构示意图")

    add_heading3("2.2.3 电路各模块介绍")
    circ_text = (
        "硬件电路主要由四部分外围接口组成：（1）MIPI CSI-2 采集接口（J4）：包含 4 对差分数据线（DATA0±~DATA3±）与 1 对差分时钟线（CLK±），Bank 电压 1.2 V，配合 3.3 V I2C（SCL/SDA）与复位引脚（XSHUTDN）完成传感器初始化与自动曝光配置；（2）DDR3 存储接口：1.5 V SSTL 电平，16 位数据总线挂载于共享 AXI4 仲裁器，供原图帧缓存、CPU 与 AI 加速器分时复用；（3）HDMI TMDS 输出接口：1.8 V 差分电平，在 148.75 MHz 像素时钟与 74.375 MHz 双像素时钟驱动下编码输出 1080p@60Hz 视频；（4）USB-JTAG/UART 与 SPI Flash 接口：板载 FT4232HL 提供单线供电、JTAG 下载与 115200 波特率串口日志通路，SPI 引脚支持软核上电后读取 Flash 中的模型固件。"
    )
    add_body(circ_text)
    add_image_if_exists('/tmp/report_media/image3.png', "图2-3  硬件外设接口与时钟域连接示意图")

    add_heading2("2.3 软件系统介绍")
    add_heading3("2.3.1 软件整体介绍")
    sw_text = (
        "片上软件运行于 100 MHz 的 32 位 Sapphire RISC-V 软核处理器（RV32IM 指令集）。固件采用精简裸机 C/C++ 架构编写，编译后包含两套完整 INT8 风格网络参数的总镜像体积约 623 KB。RISC-V 不参与逐像素计算，专门负责 Flash 启动搬移校验、双模型静态张量内存池（`tensor_arena[2]`）初始化、三级帧缓冲区租约流转、硬件卷积任务派发以及按键状态轮询。"
    )
    add_body(sw_text)
    add_image_if_exists('/tmp/report_media/image6.png', "图2-4  主固件控制流与三缓冲状态推进")

    add_heading3("2.3.2 软件各模块介绍")
    sw_mod_text = (
        "软件主要包含三个核心模块：（1）Flash 自启动引导模块（`flash_boot`）：上电后向 SPI Flash 发送 `0xAB` 唤醒指令，将位于 Flash `0x00200000` 偏移处的应用程序与模型权重搬移至 DDR3 `0x00800000` 处，完成 FNV-1a 校验后跳转执行；（2）三缓冲流水调度模块（`main.cc`）：维护采集（Capture）、推理（Inference）、显示（Display）三组缓冲区的独立租约寄存器，确保加速器绝不覆写正在显示的帧，并在 VSync 确认回执后更新 OSD 帧率计数；（3）按键交互与热切换模块：边沿检测板载按键 `SW0`~`SW2`：按下 `SW0` 时在预分配好的 Anime Sketch 与 Monet 模型句柄间切换，并同步更新硬件反量化缩放寄存器 `scale_q24` 与零点 `zero_point`；按下 `SW1` 循环切换分屏/全屏原画/全屏风格模式；按下 `SW2` 动态开关帧间线性插值。"
    )
    add_body(sw_mod_text)

    # 2.4 与 2.5 关键技术设计说明
    add_heading2("2.4 关键设计一：720p@30fps 等比空间映射与脉动行流水加速")
    opt1_text = (
        "为在有限的片上逻辑与存储资源下兼顾大视域构图与 30 FPS 实时推理性能，系统在预处理、数据流与乘加阵列三个层面进行了针对性优化：\n\n"
        "1. 基于整数 DDA 的等比空间采样与分屏 1:1 严格对齐（Aspect-Preserved DDA Scaler & 1:1 Split Alignment）：\n"
        "SC431HAI 传感器原生输出 1920×1080（16:9）视频流，若直接非等比硬压缩至方形网络输入会导致明显的人脸与物体几何拉伸形变。预处理模块采用基于整数相位累加器的数字微分分析（DDA）采样逻辑：在全屏风格模式（Mode 2）下锁定 16:9 黄金视域，从 1080p 画面提取 1280×720 有效区域（水平步进 10，垂直步进 5.625）；在分屏对比模式（Mode 0）下，创新设计了「1080p 严格等比无缝对齐架构」：右侧风格模型直接从 1080p 的右半屏（X ∈ [960, 1920), Y ∈ [0, 1080)）进行自适应变频抽样（水平步进交替 7 与 8 像素，平均步长 7.5；垂直步进 8.4375 严格覆盖全部 1080 行），与左侧原生 1080p 相机左半屏（X ∈ [0, 960), Y ∈ [0, 1080)）在空间几何尺度（统一为 1.0× 原生倍率）、垂直高度与中缝坐标上达成 1:1 绝对严密对齐。DDA 引擎利用 FPGA 内部流水寄存器在一个时钟周期内完成相位累加与坐标映射，彻底消除了分屏对比时中缝物体的比例跳跃与垂直断裂，实现了跨越中缝的无缝连贯对比！\n\n"
        "2. 片上权重驻留与行缓存流水衔接（Line-Buffer Dataflow）：\n"
        "传统逐层加速器每算完一层卷积便需将整张中间特征图写回片外 DDR，下一层再重新读出，大量带宽消耗在中间结果搬运上。本设计将离线完成批归一化（BN）折叠与 INT8 对称量化的卷积权重驻留于片上 BRAM，层间采用滑动行缓存（Line Buffer）传递特征行，前一层输出满足卷积窗口行数后即触发下一层计算，省去了中间特征图对 DDR3 的往返写回，大幅减轻总线竞争。\n\n"
        "3. 8×8 INT8 脉动乘加阵列与算子加速：\n"
        "针对卷积密集乘加运算，硬件例化 8×8 脉动计算阵列，利用片上 DSP 块每周期并行执行 64 次 INT8 乘加累加，并内联逐通道定点重缩放、ReLU 激活、四通道残差相加（`iris_rain_add`）与最近邻上采样模块。实测单帧完整推理耗时稳定在约 31,343,360 个 100 MHz 时钟周期（约 31.27 ms），实现原生 30.05 FPS 稳定吞吐。\n\n"
        "4. 三缓冲无锁仲裁机制：\n"
        "在共享 DDR3 控制器前端设置三端口 AXI4 仲裁器与三组物理输入/输出缓冲区，配合 APB 状态寄存器与 VSync 边界切换握手机制，使摄像头采集、CNN 推理与 HDMI 显示并行推进互不阻塞。"
    )
    add_body(opt1_text)
    add_image_if_exists("/tmp/report_media/image4.png", "图2-5  行流水卷积网络结构与数据流示意")

    add_heading2("2.5 关键设计二：基于 VSync 同步的硬件帧间线性插值与平滑缩放")
    opt2_text = (
        "HDMI 显示链路工作在标准 1080p @ 60 Hz（场周期 16.67 ms），而后端神经网络产生新风格帧的速率为 30.05 FPS（约每两个显示场周期提交一帧）。在默认不插帧时，同一帧风格画面会在连续两个 60 Hz 场周期内重复扫描输出；当镜头平移或人物移动时，30 FPS 的阶梯式更新在 60 Hz 屏幕上会产生一定的帧间跳变感。在不引入高昂光流计算开销的前提下，我们在显示模块（`iris_tinyml_video`）中设计了低开销的硬件帧间线性插值与行内平滑放大管线：\n\n"
        "1. VSync 周期自适应计数与帧间线性混合：\n"
        "显示控制器在每次 VSync 起始沿统计相邻两次 AI 结果提交所间隔的显示场数 `measured_period` 与当前子帧序号 `display_tick`。在子帧过渡周期内，行读取状态机分两趟从 DDR3 输出缓冲区读取同一行的上一已提交帧像素 $P_{\\text{prev}}$（暂存于片上 32×128-bit `prev_beat` 行缓存）与最新提交帧像素 $P_{\\text{curr}}$，利用纯移位加法器按子帧相位执行定点线性加权混合：\n"
        "   $$P_{\\text{out}}(x, y) = (1 - w) \\cdot P_{\\text{prev}}(x, y) + w \\cdot P_{\\text{curr}}(x, y), \\quad w \\in \\{1/4,\\ 1/2,\\ 3/4,\\ 1\\}$$\n"
        "该方式无需硬件乘法器或帧级额外显存开销，通过相邻风格帧之间的渐进式过渡，减轻了 30 FPS 帧重复输出时的突变跳动感，使 HDMI 端呈现出更柔和的 60 FPS 更新效果。\n\n"
        "2. 双像素并行反量化与水平四相位线性插值放大：\n"
        "在将网络输出张量放大映射至 1080p 屏幕区域时，若直接采用最近邻像素复制，画面容易出现块状阶梯边缘。显示流水线在 74.375 MHz 双像素时钟域下，每周期并行输出两个像素，利用相邻列像素按 `{0, 1/4, 1/2, 3/4}` 四档定点权重执行水平线性插值，随后送入两路并行硬件反量化单元（`iris_style_dequant`）根据当前风格模型的 `scale_q24` 和 `zero_point` 实时还原为 24-bit RGB 像素流，改善了放大后的线条与色块过渡自然度。\n\n"
        "3. SW2 实时开闭切换对比：\n"
        "帧间线性插值使能信号经双触发器跨时钟域同步后接入显示通路，用户可通过板载按键 `SW2` 在运行过程中随时切换「30 FPS 原生直出」与「60 FPS 帧间线性插值」两种显示状态，切换在 VSync 边界生效，无闪屏或时序中断，便于现场直观对比平滑效果。"
    )
    add_body(opt2_text)
    add_image_if_exists("/tmp/report_media/image12.png", "图2-6  采集输入、原始网络输出与显示后处理效果对比")

    # 第三部分 完成情况及性能参数（完整恢复模板要求的 3.1、3.2、3.3 结构）
    add_heading1("第三部分  完成情况及性能参数")

    add_heading2("3.1 整体介绍")
    sec3_intro = (
        "系统已完成从传感器采集、FPGA 硬件加速推理、多风格动态切换、HDMI 分屏/全屏显示到 SPI Flash 脱机自启动的全流程开发与实板联调。整机由便携式 HDMI 显示终端、握持连接支架及 Ti60F225 采集处理盒组成，整体实物正面与斜 45° 全局照片如图 3-1 所示。"
    )
    add_body(sec3_intro)
    add_side_by_side_images('/tmp/report_media/image8.jpg', '/tmp/report_media/image9.jpg', "图3-1  系统整机实物正面（左）与斜 45°（右）全局照片")

    add_heading2("3.2 工程成果")
    add_heading3("3.2.1 机械成果")
    add_body("机械结构采用 3D 打印定制外壳完成组装固定。右侧蓝色保护壳将 Ti60F225 开发板与 SC431HAI 摄像头集成为紧凑模块，预留板载按键操作窗口、散热孔位及供电接口；中部手柄支架与左侧显示屏护框通过螺钉稳固锁合，支持桌面平放演示与单手握持互动拍摄。")

    add_heading3("3.2.2 电路成果")
    add_body("FPGA 工程在 Efinity 2026.1 环境下完成综合、布局布线与静态时序分析。全设计涵盖四通道 MIPI CSI-2 接收、硬件 ISP、共享 DDR3 三端口 AXI 仲裁器、Sapphire RISC-V 软核、8×8 卷积加速阵列及 1080p HDMI 编码输出，各工作时钟域（100 MHz 核心时钟、200/400 MHz DDR3 时钟、74.375/148.75 MHz 视频时钟）均满足建立与保持时间约束，建立时间最小裕量 +0.162 ns，保持时间最小裕量 +0.026 ns。")

    add_heading3("3.2.3 软件成果")
    add_body("软件与算法侧完成了轻量化风格迁移网络蒸馏训练、INT8 量化参数导出工具、RISC-V 双模型调度固件及 Flash 引导程序开发。实机运行界面左上角通过硬件字符 OSD 实时叠加传感器采集帧率（CAM 1920x1080 60 FPS）、HDMI 输出帧率及 AI 推理/显示帧率，支持原图与风格画实时同屏对照及一键全屏切换，实屏拍摄与同帧导出结果如图 3-2、图 3-3 所示。")
    add_side_by_side_images('/tmp/report_media/image10.jpg', '/tmp/report_media/image11.jpg', "图3-2  实屏分屏对比显示与硬件 OSD 帧率叠加效果")
    add_image_if_exists('/tmp/report_media/image13.png', "图3-3  板端导出的同帧输入张量、风格推理输出与分屏合成参考")

    add_heading2("3.3 特性成果与量化测试")
    quant_text = (
        "通过板端硬件计数器、OSD 实时统计与串口日志回读，对系统各项量化指标进行了实测验证：（1）推理帧率：单帧推理耗时稳定在约 31.27 ms（31,343,360 个 100 MHz 时钟周期），原生风格化新帧速率稳定达到 30.05 FPS，高于赛题基础要求（15 FPS）与高阶要求（30 FPS）；（2）帧间插值过渡：开启 SW2 后，显示端按 60 Hz 场周期执行相邻帧线性混合过渡，OSD 显示更新率稳定在 60 FPS，减轻了慢速移动场景下的跳变感；（3）多风格切换响应：按下 SW0 在 Anime Sketch 与 Monet 两套模型间切换时，仅需切换已驻留内存的模型指针与反量化寄存器，实测切换响应延迟小于 60 ms（满足 <100 ms 要求）且不丢帧；（4）长时间运行稳定性与脱机启动：连续运行超过 2 小时（逾 220,000 帧），显存读取欠载（Underflow）、总线读错误（ReadErr）与非法请求拒绝（Rejects）计数全程保持为 0；断电拔除下载线后仅用 Type-C 供电，约 2.8 秒即可自动从 SPI Flash 完成固件加载校验并输出实时风格化画面。"
    )
    add_body(quant_text)

    # 第四部分 总结
    add_heading1("第四部分  总结")

    add_heading2("4.1 可扩展之处")
    ext_text = (
        "作品采用模块化架构设计，后续可从以下三方面进一步拓展：（1）扩展更多预置艺术风格：当前 8 MB SPI Flash 仍有约 5 MB 剩余空间，可继续存入浮世绘、水墨画、梵高星空等更多风格权重实现多档轮换；（2）融合自然交互方式：结合赛题创意交互建议，利用 I2C/SPI 扩展手势传感器或离线语音识别模块，实现挥手或语音指令切换风格；（3）无线视频推流：通过板载千兆以太网或外接 WiFi 模块，将实时风格化画面推送至手机端预览保存。"
    )
    add_body(ext_text)

    add_heading2("4.2 心得体会")
    exp_text = (
        "在本次嵌入式芯片与系统设计竞赛的备赛过程中，团队完整经历了模型蒸馏量化、FPGA 微架构设计、RTL 仿真、多时钟域时序收敛与板级固化的工程闭环，三位队员结合各自模块总结如下：\n\n"
        "【参赛队员甲（轻量化网络设计与 INT8 量化）】：\n"
        "「项目初期尝试直接移植较大规模的风格迁移网络，但受限于片上存储与乘加带宽无法实时运行。通过算力拆解，我们采用知识蒸馏与通道裁剪将模型压缩至数百 KB 内，离线将批归一化（BN）折叠进卷积参数，并用全整数 INT8 量化与移位重缩放替代浮点运算，在显著降低硬件开销的同时与 TFLite 整数参考保持了逐字节一致。」\n\n"
        "【参赛队员乙（FPGA 视频链路、脉动加速与时序收敛）】：\n"
        "「硬件调试让我深刻体会到外部访存带宽往往比算力更早成为实时瓶颈。若每层特征均写回 DDR3，总线很快饱和。通过采用片上权重驻留、行缓存（Line Buffer）级联流水与 8×8 INT8 脉动阵列，中间特征无需回写片外内存，单帧推理稳定在 31.27 ms。同时，针对 MIPI、核心与 HDMI 多时钟域交互，通过规范异步 FIFO 握手、VSync 边界同步与 SDC 约束，消除了早期的偶发撕裂与时序违例。」\n\n"
        "【参赛队员丙（RISC-V 软核驱动、三缓冲调度与 Flash 固化）】：\n"
        "「软核在异构系统中承担着状态调度与容错保护职责。通过独立租约的三缓冲机制，采集、推理与显示严格互斥，连续数小时运行保持零欠载、零错帧。在实现 SPI Flash 脱机冷启动时，我们核对了配置后 Flash 唤醒等待与 SPI 采样相位延迟，编写了带 FNV-1a 校验的轻量级引导程序，实现了拔除下载线后单线供电 2.8 秒上电自启动。」\n\n"
        "【团队总结】：\n"
        "「从打通相机至 HDMI 直通链路，到实现 720p@30fps 推理、双风格快速切换、60Hz 帧间线性插值过渡与脱机自启动，每一次排障都强化了『用实测数据说话、按真实硬件时序设计』的工程意识。感谢竞赛组委会与易灵思平台支持，以及指导老师的悉心指导。」"
    )
    add_body(exp_text)

    # 第五部分 参考文献
    add_heading1("第五部分  参考文献")
    refs = [
        "[1] Gatys L A, Ecker A S, Bethge M. Image Style Transfer Using Convolutional Neural Networks[C]// IEEE Conference on Computer Vision and Pattern Recognition (CVPR), 2016: 2414-2423.",
        "[2] Johnson J, Alahi A, Fei-Fei L. Perceptual Losses for Real-Time Style Transfer and Super-Resolution[C]// European Conference on Computer Vision (ECCV), 2016: 694-711.",
        "[3] Zhu J Y, Park T, Isola P, et al. Unpaired Image-to-Image Translation Using Cycle-Consistent Adversarial Networks[C]// IEEE International Conference on Computer Vision (ICCV), 2017: 2223-2232.",
        "[4] Hinton G, Vinyals O, Dean J. Distilling the Knowledge in a Neural Network[J]. arXiv preprint arXiv:1503.02531, 2015.",
        "[5] Howard A G, Zhu M, Chen B, et al. MobileNets: Efficient Convolutional Neural Networks for Mobile Vision Applications[J]. arXiv preprint arXiv:1704.04861, 2017.",
        "[6] Jacob B, Kligys S, Chen B, et al. Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference[C]// IEEE Conference on Computer Vision and Pattern Recognition (CVPR), 2018: 2704-2713.",
        "[7] David R, Duke J, Jain A, et al. TensorFlow Lite Micro: Embedded Machine Learning on TinyML Systems[C]// Proceedings of Machine Learning and Systems (MLSys), 2021, 3: 800-811.",
        "[8] Kung H T. Why Systolic Architectures?[J]. Computer, 1982, 15(1): 37-46.",
        "[9] Chen Y H, Emer J, Sze V. Eyeriss: An Energy-Efficient Reconfigurable Accelerator for Deep Convolutional Neural Networks[J]. IEEE Journal of Solid-State Circuits, 2017, 52(1): 127-138.",
        "[10] Waterman A, Asanović K. The RISC-V Instruction Set Manual, Volume I: User-Level ISA[R]. RISC-V Foundation, 2017.",
        "[11] SmartSens Technology. SC431HAI CMOS Image Sensor Datasheet (V1.1)[Z]. 2024.",
        "[12] Efinix Inc. Titanium Ti60F225 Data Sheet and User Guide[Z]. https://www.efinixinc.com, 2025.",
        "[13] Efinix Inc. Sapphire RISC-V SoC User Guide[Z]. https://www.efinixinc.com, 2025.",
        "[14] MIPI Alliance. MIPI Alliance Specification for Camera Serial Interface 2 (CSI-2)[S]. 2017.",
        "[15] GigaDevice Semiconductor Inc. GD25LQ64C 1.8V 64M-bit Serial Flash Memory Datasheet[Z]. 2021."
    ]
    for r in refs:
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(3)
        p.paragraph_format.line_spacing = 1.15
        run = p.add_run(r)
        run.font.name = 'Times New Roman'
        run._element.rPr.rFonts.set(qn('w:eastAsia'), '宋体')
        run.font.size = Pt(9.5)

    doc.save(output_path)
    print(f"Successfully generated {output_path}")


if __name__ == '__main__':
    create_report()
