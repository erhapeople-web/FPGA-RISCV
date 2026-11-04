# 精确 2.506126850 分 CoreMark 完整复测工程

这是本轮实际测得 P=2.506126850、V=2.406842362 CoreMark/MHz 的同一份 RTL、CoreMark ROM 和冻结位流。100MHz、RV32I无M/C、GCC15.2/-O2、两路I/D Cache与AXI、FOUR_FUSION=0，2000字节数据，P/V各5000次。请先使用包内冻结位流复测，再考虑重编译。

## 准备

需要 Windows x64、64位Python3.10+、PDS2022.2-SP6.4 build146967及原生下载驱动。包内带pyserial3.5和psutil7.2.2离线wheel，无需联网安装。Python和PDS为外部安装依赖，未把PDS软件打入包内。

完整解压到无空格、无中文的短路径，例如 `E:\J5_CM2506`。连接盘古200Pro+供电、JTAG和CP210x串口；在设备管理器确认CP210x的COM号。关闭占用该串口或JTAG的其他工具。只需CPU跑分，摄像头/HDMI显示内容不是验收条件。

在解压目录打开PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\run.ps1 -Port COM11 -PythonExe python -PdsBin '你的PDS目录\bin'
```

`run.ps1` 默认依次执行P、V，每组全新配置SRAM，完成后正常清板。单独复测可用 `run_P.ps1`、`run_V.ps1`，或 `run.ps1 -Mode P` / `-Mode V`，其他参数相同。若Python不在PATH，把 `-PythonExe` 改为实际python.exe路径。必须选择实际CP210x的COM号；程序会核对USB VID/PID和唯一性。

首次初始化也可只运行 `setup.ps1`，不接触板卡；`check.ps1` 只核对包内文件。原生工具按实测文件哈希检查，版本不匹配会在编程前拒绝。JTAG使用独占本机65446端口。每次只启动一轮脚本。

## 结果与停止

成功时打印 `COREMARK_VERIFIED`，包含精确周期、秒数、CoreMark/MHz及是否与本轮参考周期相同。原始数据在 `runs/`；`verified_result.json` 综合核对实际下载身份、原始UART、nonce/SOURCE_ID、完整CRC、至少10秒、OT及正常清SRAM。分数以64位CPU周期换算，串口整数时间/Iterations/Sec存在截断。

参考P：1,995,110,503周期、19.95110503秒；参考V：2,077,410,668周期、20.77410668秒。P的CRC为e9f5/e714/1fd7/8e3a/bd59；V为18f2/e3c1/0747/8d84/f440。CPU数据在经过D-Cache/AXI的本地SRAM，代码ROM经I-Cache；Cache计数包括冷启动及命令等待，不只是计时内核。

运行中用 `stop.ps1` 请求STOP，并等待控制器确认清板。保留ALARM/原生OT、转换超时、300秒片上保护、285秒主机活跃限时、独立看门狗和精确自有进程检查。发生读取/连接/CRC错误会停止，不自动重试或继续下一组；若清板未确认，先恢复供电/JTAG并处理该状态。只配置SRAM，不写Flash。

## 工程与重建

PDS入口 `pds/test_ddr.pds`，有效构建脚本 `pds/build.tcl`。`src/`、`constraints/`为完整源输入；`firmware/coremark/upstream/`保留官方源码和许可证，`port/`为本次移植层。预编译ELF在 `firmware/coremark.elf`，BIN/HEX/ROM初始化在 `src/firmware/`，冻结位流在 `bitstream/test_ddr.sbit`。

```powershell
.\build_fpga.ps1 -PythonExe python -PdsBin '你的PDS目录\bin'
.\build_firmware.ps1 -PythonExe python -ToolchainBin '你的GCC15.2工具链\bin'
```

重建输出放入 `build/`，不会替换冻结的下载位流或ROM。固件重建固定原SOURCE_ID、编译器字节及原编译方式，检查生成物是否与本轮冻结产物相同。仅换ROM源码后不能复用旧位流的资格；新硬件产物须重新完成功能、最终时序、ROM/CDC及实板验证。

## 身份与范围

SOURCE_ID：`07b7f5a7855dc267d61c692e69655f4c89158117461adfc2f6d55c9cbce16e47`。

- 固件BIN SHA256：`f915be488b671606ba957bbf027760cee914ca120e5bbaac2c95e677ea00f6c3`。
- 位流SHA256：`94139808dc8e89ea3fd5758a559f101f1ed90ddaa50c26377b11b4a86d59c744`。

`records/measured_20261103/`包含本聊天两轮真实实板记录和原始UART；资格摘要及对应JSON保留在 `qualification/`。主机迁移只调整包内路径、PDS安装位置和串口选择，原编程/看门狗/OT/清板机制保留，并重新执行迁移后的离线控制测试。历史报告中的绝对路径是证据来源，不是运行依赖。

最终时序CPU setup/hold +0.519/+0.028ns，uncertainty0.500/0.200ns；约束通过，hold低于+0.050ns工作目标。CoreMark/LUT采用全SoC模块LUT23710作分母。此包精确保留产生本轮成绩的单文件入口重命名编译方式，不替换为其他新ROM，也不宣称严格EEMBC发布规则合规或认证。
