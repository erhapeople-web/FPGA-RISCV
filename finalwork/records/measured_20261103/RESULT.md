# J5_CAMERA_8S 上板跑分验证

日期：2026-11-03。对象：`E:\study1\FPGA\deliveries\J5_CAMERA_8S`。

原目录 221 个文件逐项哈希复核，均保持原字节。126 个有效设计输入、5 个约束、PDS 设置及全部打包非 ROM 源码与已有准入 CoreMark 工程一致。复用该精确测试构建的功能、最终时序、ROM、CDC 和板控资格，重新执行以下两轮 SRAM 实板测试；没有以旧分数代替本轮运行。

100 MHz，GCC 15.2.0，-O2，RV32I 无 M/C，真实两路 I/D Cache 和 AXI，FOUR_FUSION=0，TOTAL_DATA_SIZE=2000 B，P/V 各5000次。

| 模式 | 精确 CPU 周期 | 秒 | CoreMark | CoreMark/MHz | CoreMark/LUT | 有效 OT 样本 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| P | 1995110503 | 19.95110503 | 250.612684986 | 2.506126850 | 0.010569915 | 3 |
| V | 2077410668 | 20.77410668 | 240.684236248 | 2.406842362 | 0.010151170 | 3 |

按图中赛题一公式，以实际64位CPU周期和100MHz换算：CoreMark = 5000 / 秒；CoreMark/MHz = 5000 × 1,000,000 / 周期。两轮均至少10秒，全部kernel CRC及crcfinal与已核验身份的独立5000次参考一致。

| 模式 | seedcrc | crclist | crcmatrix | crcstate | crcfinal | 清 SRAM 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| P | e9f5 | e714 | 1fd7 | 8e3a | bd59 | 0x00180c80 |
| V | 18f2 | e3c1 | 0747 | 8d84 | f440 | 0x00180c80 |

每轮全新配置SRAM、正常清板并关闭自有JTAG服务，没有看门狗兜底复位；所记录原生OT均未报警，无读取失败。原300秒保护、ALARM/OT、转换活性、STOP及独立看门狗保留，未写Flash，未采集实际温度。

| 模式 | I 访问 | I 缺失 | D 访问 | D 缺失 |
| --- | ---: | ---: | ---: | ---: |
| P | 1244583940 | 814 | 466597298 | 400197 |
| V | 1307486861 | 818 | 477213743 | 421459 |

Cache计数为冷复位至结果输出后的累计值，包括启动、命令等待、初始化和UART输出；不是计时内核单独窗口。数据在经D-Cache/AXI的本地SRAM，代码ROM经I-Cache；未称为DDR驻留跑分。

专用跑分位流最终布线CPU setup/hold +0.519/+0.028 ns，uncertainty 0.500/0.200 ns，各组非负；hold低于+0.050ns工作目标。100MHz是本次配置频率，没有执行最高频率搜索。

资源效率分母为最终PDS全SoC顶层模块LUT23710，包含摄像头和显示；FF15571、Distributed RAM934、DRM178.5、APM17。CPU模块LUT11696及物理CLMA/CLMS LUT26490是其他统计口径，未混用。

本轮替换为独立CoreMark测试ROM，不是AI应用固件自身或AI并发吞吐测试。沿用移植中core_main.c单独入口重命名宏；HAS_FLOAT=0的原UART整数时间/速率有截断，本报告使用精确周期，不据此宣称严格完整EEMBC发布规则合规或认证。

测试固件 SHA256：`f915be488b671606ba957bbf027760cee914ca120e5bbaac2c95e677ea00f6c3`。
测试位流 SHA256：`94139808dc8e89ea3fd5758a559f101f1ed90ddaa50c26377b11b4a86d59c744`。

原始UART、带nonce命令、SOURCE_ID、下载绑定、OT和清板的逐项哈希保存在 `RESULT.json`；源身份在 `hardware_binding.json`。

- P 原始运行：`E:\study1\FPGA\test\board_runs\20261103_131518_954625_c8cc8e02_coremark_P`。
- V 原始运行：`E:\study1\FPGA\test\board_runs\20261103_131705_640774_9760dc62_coremark_V`。
