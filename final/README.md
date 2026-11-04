# J5 Bugfix：完整可运行的 8 秒版本

解压后具备完整源码、固件、已验证位流、模型/OPS、实际主机控制和离线 Python 依赖。8 秒清板已在实际脚本中实现，无需从 MD 复制补丁。PDS 工程入口为 `pds/test_ddr.pds`。请把整个目录解压到无空格、无中文的短路径，例如 `E:\J5_CAMERA_8S`；旧版 PDS 原生下载工具无法可靠执行带空格路径的脚本，初始化会提前检查并拒绝不适用路径。

## 准备与运行

需要 Windows x64、64 位 Python 3.10+（本机验证使用 3.14.4）、PDS 2022.2-SP6.4 build146967 及其下载驱动。连接盘古 200Pro+ 的 JTAG、COM11 对应 CP210x USB、摄像头和 HDMI 显示器。

在解压目录执行：

```powershell
.\setup.ps1 -PythonExe 'python' -PdsBin '你的PDS安装目录\bin'
.\run.ps1 -PythonExe 'python' -PdsBin '你的PDS安装目录\bin'
```

本机参数示例：`-PythonExe 'D:\Python\Python314\python.exe' -PdsBin 'D:\FPGA2\PDS_2022.2-SP6.4\bin'`。

`setup.ps1` 只核对文件、使用包内 wheel 安装 Python 依赖到 `.runtime/` 并绑定本地路径，不接触板卡、不联网安装依赖、不要求原工作区存在。`run.ps1` 自动调用 setup 后配置 SRAM、上传模型、执行真实相机帧推理；收到 OSD 完成通知后计满 8 秒（含快照读回）进入正常清板。OT 客户退出与清 SRAM 验证另需时间。

`check.ps1` 仅核对文件。运行中可执行 `stop.ps1` 请求 STOP，等待日志确认清 SRAM；不要同时开启两轮运行。原 ALARM0/OT、转换活性、300 秒片上保护、独立看门狗和精确进程归属检查保留。只用 SRAM，不写 Flash，不运行 CoreMark。

每轮原始记录在 `runs/`。查看最近目录的 `application_result.json`（检测坐标/类别）、`controller_result.json`（8 秒计时和清板）、`wrapper_result.json`（总结果）。本版 COCO 类别 64=MOUSE、66=KEYBOARD；板上 OSD 原逻辑仅画框，文字标注图属于保存帧的离线可视化。

## 重建

```powershell
.\build_fpga.ps1 -PythonExe 'python' -PdsBin '你的PDS安装目录\bin'
# 或仅检查编译：增加 -CompileOnly
.\build_firmware.ps1 -ToolchainBin '你的RISC-V GCC目录\bin' -PythonExe 'python'
```

FPGA 构建产物写入 `build/`，不会覆盖已验证的 `bitstream/test_ddr.sbit`。GUI 打开 PDS 也可构建；新 RTL、ROM 或位流必须重新完成功能、最终时序、ROM/CDC 与板测资格，不能把新输出覆盖冻结位流绕过检查。

## 资格与范围

运行时使用与此前通过资格及实板的版本完全相同的 RTL、ROM、模型、位流和板控 Python 代码。`qualification/baseline_gate.json` 和必要的原始 JSON 报告用于身份核对；setup 仅在源文件、模型、实际工具字节及全部已保存资格匹配时生成本机路径门禁，没有取消门禁。PDS 元数据已按原生格式修复。

历史 CPU 最终 setup/hold +0.519/+0.028ns，uncertainty 0.500/0.200ns；hold 尚低于 +0.050ns 工作余量目标。主机控制 108 项离线检查通过；两次 8 秒版板测均清 SRAM，最近一轮 119 节点 56.66346444 秒，返回 MOUSE/KEYBOARD，OT 15 条未报警；白色键盘仍漏检。新包自身的复核记录见 `records/RUNNABLE_VALIDATION.md`（完成复核后补充）。

为减少体积，本包不携带旧 PDS 数据库、综合网表、仿真大文件、重复位流、UART 原始收发备份和独立参考的内存转储。这些历史留档不是运行依赖。
