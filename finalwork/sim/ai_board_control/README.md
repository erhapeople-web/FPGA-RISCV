# AI 摄像头单帧板控

本目录是离线故障注入测试；运行 `python -B -X utf8 sim/ai_board_control/run_tests.py` 不启动子进程、不打开 UART/JTAG。真实入口为 `tools/run_ai_camera_board.py`，须由集成负责人最终审查后调用。

## 新门禁格式

`evidence/BOARD_GATE.json` 必须含：

```json
{
  "schema": "AI_CAMERA_BOARD_GATE_V1",
  "passed": true,
  "scope": "J5_AI_CAMERA_20261031",
  "candidate_root": "E:/study1/FPGA/test/J5_AI_CAMERA_20261031",
  "bitstream": {"path": "pds/generate_bitstream/test_ddr.sbit", "sha256": "实际64位小写SHA256"},
  "source_hashes": {"候选内相对文件路径": "实际SHA256"},
  "proof_hashes": {"候选内证明JSON路径": "实际SHA256"},
  "dependency_hashes": {"--dependencies输出的每个绝对路径": "实际SHA256"},
  "required_proofs": {
    "functional": "当前功能证明JSON",
    "timing": "当前routed时序证明JSON",
    "rom": "当前ROM证明JSON",
    "cdc": "当前CDC证明JSON",
    "host_workload": "当前workload离线证明JSON",
    "board_controls": "evidence/ai_board_control/result.json"
  }
}
```

这是格式说明，不能作为实际门禁。六类证明须为六个独立的、已哈希且自身 `passed=true` 的 JSON。`source_hashes` 必须覆盖实际 build.tcl 的全部设计/约束输入、ROM 文件、host Python 文件、identity 和新板控脚本；路径逃逸、遗漏、旧候选 scope、非布尔通过值、代码/证明/位流变化均拒绝。`dependency_hashes` 与 `--dependencies` 的完整输出必须一致。门禁失败在创建 run 和启动设备前退出。

只检查：`python -B -X utf8 tools/run_ai_camera_board.py --check-only`。依赖清单：同入口加 `--dependencies`。这两个选项不访问板卡。

## 运行边界

- 外层独立 Python、controller、watchdog 三进程；JTAG 只使用自有 65446 端口和精确进程身份。旧版 gate 没有被借用或修改。
- 单次 SRAM program，禁止 Flash/CoreMark；电脑不推理。只有 root 提供的 `camera_workload.run_workload(link,run,check,progress_callback=None)` 执行上传、一次 RUN、板上推理和结果记录。
- 串口 COM11、921600 baud，短读写超时。单独接收线程持续记录原始 RX，应用只消费队列；不丢弃启动字节。TX 记录实际交给驱动的字节。
- baseline 原生 OT 必须为 0；配置完成状态正常后启动原生 OT 观察器，约每 10 秒读 bit27，实际时间记录在 samples.jsonl。读错、缺失/陈旧、OT=1、STOP 和程序错误均取消；未采样不能伪记 0。没有电脑端摄氏温度采集。
- 从 program 开始计算主动工作上限 285 秒，片上 300 秒保护不改。watchdog 390 秒预算包含下载和清理，提前保留独立接管、客户停止和原生复位时间；外层另有总限兜底。
- 正常 finally 先关闭 UART、停止观察器并确认其原生客户退出，才复位。成功清板要求原生 raw 精确为 `0x00180c80`。未确认客户停止时不并发复位，独立 watchdog 可接管。
- 接管先暂停/复核本 controller，发现并停止其自有原生客户；外层也覆盖已死 watchdog 的原生孤儿客户。存活客户只有完整 PID/create_time/exe/cmdline/cwd 身份吻合才可停止；不按进程名杀其他 PDS/JTAG。controller/watchdog 的身份复用仍阻止接管。
- 本候选显式加载本地 `host/native_ot_observer.py`，使用本地只读 `host/native_client_lifecycle.py`。原生客户若有完整匹配 owner 的整数 returncode 退出记录，并且该 PID 已不存在或当前创建时间不同，则旧客户确已退出。不同创建时间的进程只读取 PID/创建时间，不读取其它属性、不终止。创建时间相同但其它身份不匹配、缺失／不匹配退出记录、无法观察进程或观察器线程仍活，继续禁止并发复位。非零 returncode 只证明进程退出，不能证明命令或 AI 功能成功。
- 最终通过同时要求 workload 通过、正常 controller/watchdog 退出、无 STOP/兜底替代、清板核验和自有 server 关闭。救援清板成功只证明清理完成，不会变成 AI 功能通过。

当前默认系统 Python 没有 `psutil`。既有板控实测使用 `E:/Anaconda/envs/psychopy_env/python.exe`；真实运行需在有 `pyserial/psutil` 的解释器中执行，并先检查门禁。此说明不代表本轮已经访问设备。

PID复用修复已执行原45项及新增26项，共71项fake-only测试。新增测试实际调用本地观察器和Controller，验证旧客户退出后PID复用可清理、285秒失败能清理且仍为功能失败、相同创建时间的身份不匹配继续阻止复位。`ForeignBirthOnly` 假进程只允许读取PID/创建时间，任何其它接触立即使测试失败。修复前同一新复现明确失败的46项日志与源码快照在 `evidence/ai_board_control/pid_reuse_before/`；这些是离线诊断，不能改写第一次板测的失败结果。
