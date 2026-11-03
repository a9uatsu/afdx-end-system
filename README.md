# AFDX 端系统工程（赛题选题一）

全国大学生嵌入式芯片与系统设计竞赛'2026 FPGA 创新设计赛道 —— **选题一：基于以太网 MAC 总线实现 AFDX**

- 工程文件：`test.epr`（eLinx 工程）
- 器件：EQ6HL130 / CSG484_H（eHiChip6）
- 顶层：`AFDX_top`，端口与赛题模板逐字一致
- 语言：Verilog-2001
- 时序约束：50 MHz
- 设计文档：[doc/设计文档.md](doc/设计文档.md)
- 测试报告：[doc/测试报告.md](doc/测试报告.md)
- 任务报告：[doc/任务报告.md](doc/任务报告.md)
- P2 验收记录：[doc/P2_验收记录.md](doc/P2_验收记录.md)

## 目录结构

```text
test.srcs/sources_1/afdx/   RTL：16 个 .v + afdx_defs.vh
test.srcs/sim_1/afdx/       14 个测试平台
test.srcs/constrs_1/new/    afdx_top.sdc、test.edc
scripts/                    一键回归、Python 参考模型与校验器
sim/vectors/                可复现测试向量与期望结果
sim/work/                   仿真日志和中间产物
doc/                        设计、测试、任务及各阶段验收记录
doc/refactor_baseline/      阶段回退点与 eLinx 报告归档
```

## 一键回归

```powershell
cd <仓库目录>
python scripts\check_multidriver.py test.srcs\sources_1\afdx
powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
```

ModelSim SE-64 回归（默认安装路径为 `C:\modeltech64_10.7\win64`）：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_modelsim.ps1
# 自定义工具目录与输出目录：
powershell -ExecutionPolicy Bypass -File scripts\run_modelsim.ps1 -ModelSimBin "C:\path\to\modelsim\win64" -RunDir "C:\temp\afdx-modelsim"
```

仅运行 CRC/校验和库测试，可直接双击 `scripts\run_lib_modelsim.bat`；它会启动 ModelSim GUI 并自动加载、运行测试，窗口保持打开。结束时源码行 111 的 `$finish` 是正常退出点，`Break at` 只表示 ModelSim 在 `$finish` 停止；请以 Transcript 的 `RESULT: PASS` 为准。

脚本会编译全部 RTL/TB、运行 14 个仿真用例并执行 7 项 Python 独立校验。任一编译、运行或参考校验失败都会返回非零退出码；日志与本次输出保存在 `sim\modelsim\`。

当前回归包含 22 项，全部 PASS：

```text
static / lib
tx / tx_frame_check
tx_capacity / tx_capacity_check
tx_full / tx_full_check
soak / soak_check
rx / rx_check
rm_capacity / rm_full
top
snmp / snmp_check
snmpnet / snmp_net_check
rtc / load / perf
```

`soak` 使用 128 条发送 VL、BAG 1/2/4 ms 混合，运行 12,000 帧。实测每条 VL
40-160 帧，最差 BAG 余量 +80 ns，最大抖动 2.6 us，字段/校验和/FCS/SN 错误 0。
逐 VL 统计见 `sim/vectors/soak_expect.txt`。

如果 Icarus Verilog 不在 PATH 中，可使用 `-IverilogRoot` 指定安装目录，例如：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1 -IverilogRoot "C:\path\to\iverilog"
```

## 已实现功能

- AFDX 帧封装/解析、VLID、SN、UDP/IP、IPv4/UDP 校验和、CRC-32 FCS；
- 128 发送 VL：4-bank VL 表、后台扫描、就绪 FIFO、BAG 整形与轮询仲裁；
- 4096 接收 VL：VLID 二分查找、RM 状态 RAM、序列号检查与读改写；
- A/B 双网口、副本去重、失序恢复、过期丢弃、帧错误窗口与 VL 故障；
- SNMP v2c：Get / GetNext / Set / Trap，端口 161；
- RTC：端口 123；
- ARINC 615A：WRQ / DATA / ACTIVATE / READ，端口 10000；
- 性能：等效发送吞吐 130.1 Mbps；64/1517 字节帧时延 1.87/89.63 us。

## 最终实现

```text
LUT      : 14,059 / 136,160 (10%)
FF       :  3,876 / 136,160 (3%)
Memory   :     46 / 1,200 (4%)
DSP      :      0 / 48
Pins     :     22 / 339
WNS      : +1.411 ns @ 50 MHz
Fmax     : approx. 54.0 MHz
Route err: 0
```

最终 eLinx 产物：

```text
test.runs/imple_1/test.psk
test.runs/imple_1/test_comp.psk
```

BitGen 日志结论为 `Bitgen all was well`。文件哈希和报告见
`doc/P2_验收记录.md`。

`test.runs/`、`db/`、`incremental_db/`、ModelSim 库目录和波形文件均为
可再生的构建/仿真产物，不纳入版本控制；仓库保留最终报告、哈希记录、
测试平台、测试向量和精简回归日志。

## 引脚约束说明

`test.edc` 已为全部 22 个顶层端口分配合法、唯一且未被 BlockedIO 占用的
CSG484_H 引脚，因此工程可以完成实现和 BitGen。

这些位置是为验证工具链选择的通用 I/O 位置，不是具体开发板引脚图。
上板前必须依据实际板卡原理图替换为对应位置。

## eLinx 使用约定

- Design Sources 只登记 RTL 与 `afdx_defs.vh`；
- Simulation Sources 只登记测试平台；
- Synthesis 顶层为 `AFDX_top`；
- Implementation 使用 `afdx_top.sdc` 和 `test.edc`；
- eLinx 自带 Verilator 为精简安装，命令行仿真使用 Icarus Verilog。

## 代码规范

- 端口、信号、寄存器小写；参数大写；
- 关键段使用中文注释；
- 顶层端口名称、位宽、方向与赛题模板一致；
- RTL 使用 Verilog-2001 子集，不依赖厂商专用原语。

## 剩余优化项

1. SNMP GetBulk / 多 varbind；
2. 真实应用侧数据寄存器/FIFO 写入口；
3. 双网口独立解析通路及副本重叠测试。
