# J5 竞赛代码提交说明

压缩包包含两套独立的盘古 200Pro+（PG2L200H）工程。请将完整压缩包解压到短的英文路径，例如 F:\J5_SUBMIT。路径请避开空格和中文，并保留各工程的目录结构。

| 目录 | 用途 | 板上运行内容 | 查看结果 |
| --- | --- | --- | --- |
| final/ | 摄像头目标识别与 HDMI 展示 | 采集 OV5640 画面，在 FPGA 上运行量化模型并叠加检测框 | HDMI 查看检测框，串口返回类别、置信度和坐标 |
| finalwork/ | CoreMark 跑分 | 在 100 MHz 下执行 RV32I CoreMark，P/V 两组各 5000 次 | 控制台输出 COREMARK_VERIFIED，运行目录保存精确周期、CRC 和分数 |

两套工程各有自己的固件和冻结位流。运行脚本会加载当前工程的位流，并在完成后清理 FPGA 配置 SRAM。请按顺序运行两套工程，每次只使用一套 JTAG 和串口会话。

## 打开 PDS 工程

- 图像识别展示打开 final/pds/test_ddr.pds。
- CoreMark 跑分打开 finalwork/pds/test_ddr.pds。

使用 PDS 2022.2-SP6.4 build146967 打开工程，可以查看 RTL 和管脚约束，也可以执行综合与布局布线。工程的源码及约束通过相对路径引用。上板复现使用下面的 run.ps1，由它调用下载工具加载包内已验证的 bitstream/test_ddr.sbit，再执行串口流程。构建说明见各工程自己的 README.md。

## 上板前准备

1. 在 Windows x64 上安装 64 位 Python 3.10 或更新版本、上述版本的 PDS 及下载驱动。两套工程的 Python 依赖均在 vendor/wheels/，运行脚本会离线安装。
2. 连接开发板供电、JTAG 和 CP210x USB 串口，在设备管理器中确认 COM 号，关闭占用 JTAG 或串口的工具。展示工程还需连接 OV5640 摄像头和 HDMI 显示器。
3. 以下两组命令各自从解压后的根目录开始执行。把 -PdsBin 改成实际 PDS 安装目录的 bin 路径。Python 不在 PATH 时，把 -PythonExe python 改成 Python 可执行文件的完整路径。

## 运行图像识别展示

展示工程沿用原验证配置，要求 CP210x 串口为 COM11。

    cd .\final
    powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 -PythonExe python -PdsBin 'C:\pango\PDS_2022.2-SP6.4\bin'

脚本配置 FPGA 后上传模型与算子描述，触发一次真实摄像头推理。收到显示完成通知约 8 秒后开始清板。检测结果和清板状态见 final/runs/ 最新一轮的 application_result.json 和 wrapper_result.json。

## 运行 CoreMark 跑分

把示例中的 COM11 改成设备管理器中 CP210x 的实际 COM 号。

    cd .\finalwork
    powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 -Port COM11 -PythonExe python -PdsBin 'C:\pango\PDS_2022.2-SP6.4\bin'

默认依次执行 P（性能组）和 V（验证组）。只跑一组可加 -Mode P 或 -Mode V。结果见 finalwork/runs/ 各轮的 verified_result.json。包内原始实板记录位于 finalwork/records/。参考实测成绩为 P 组 2.506126850、V 组 2.406842362 CoreMark/MHz。

如需离线校验，在对应工程目录执行 check.ps1，并传入同样的 -PythonExe 和 -PdsBin。上板过程中可在另一个 PowerShell 窗口从对应工程目录执行 stop.ps1，等待运行日志确认清理完成。

## 实测证据

final/records/ 保存摄像头展示的板测摘要。finalwork/records/ 保存 P/V 实板复测、原始 UART 和校验记录。report_evidence/ 保存资源报告和流水线四个采样窗口的波形及串口数据。

report_evidence/wave_capture/ 的波形来自独立的采样镜像，采样镜像成绩为 2.503871232 CoreMark/MHz。计分成绩对应 finalwork 的冻结固件和位流。该实测成绩未作为 EEMBC 认证成绩。
