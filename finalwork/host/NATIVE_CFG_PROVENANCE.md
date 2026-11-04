# 原生板控 API 来源

`host/native_cfg.py` 逐字复制自 `E:/study1/FPGA/test/J5_CPU_LOAD_20261030/host/native_cfg.py`，未修改；SHA256 为 `aee8005450e8eadde7a51bfdb92aeee874804052a10ee0157159e6125dd6b8be`。该代码提供原生状态读取、一次 SRAM 下载、配置复位及完整进程身份检查，不在 import 时执行硬件操作。

`tools/run_ai_camera_board.py` 仅借用下列已测源码中的机械接口：

- `J5_CPU_LOAD_20261030/tools/run_cpu_load_board.py`：`ServerManager`、精确身份的 Python 子进程启动与端口检查。其模块导入会读取同父版的 `cpu_load_qualification.py/native_cfg.py`，因此两者也封入依赖哈希。
- `J5_CPU_SOAK_20261031/host/native_ot_observer.py`：周期读取原生配置状态 bit27，停止时确认原生子客户退出。该模块自身显式导入父版 NativeCFG；新本地副本保持相同字节。
- 本机 `cdt_js.exe`、`cdt_cfg_shell.exe`：运行时依赖列表同时记录这两个工具的 SHA256。

上述历史工程只提供接口实现，不提供新候选的板测准入。新脚本不调用旧 `qualified_inputs/Controller`，不修改旧模块或 monkeypatch 旧资格检查；新位流只能由当前候选的 `evidence/BOARD_GATE.json` 放行。`--dependencies` 输出全部依赖文件及当前 SHA256，根门禁必须逐项绑定。

这些外部代码路径是当前工作区的运行依赖，不能把本脚本单独复制后宣称接收机可以直接板测。移交若要独立执行，需同时整理接口源码、工具安装及来源，并重新封门验证。
