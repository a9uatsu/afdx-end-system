# S1b 验收记录：管理通道缓冲 RAM 化

日期：2026-11-03  
范围：`afdx_mgmt_path`、`afdx_snmp_agent`、`afdx_load_615a`  
顶层：`AFDX_top`，4 TX VL / 8 RX VL，`EN_MGMT=1`

## 1. 回退点

- `doc/refactor_baseline/afdx_mgmt_path_S0.v`
- `doc/refactor_baseline/afdx_snmp_agent_S0.v`
- `doc/refactor_baseline/afdx_load_615a_S0.v`
- `doc/refactor_baseline/afdx_top_pre_EN_MGMT1.v`
- 时序修复前补充回退点：
  - `afdx_snmp_agent_S1b_pre_timing.v`
  - `afdx_mgmt_path_S1b_pre_pmem_sync.v`

## 2. S0 独立综合基线

`afdx_mgmt_path` 作为顶层、管理通道未 RAM 化时：

| 项目 | S0 |
|---|---:|
| Logic elements | 125,893 |
| Registers | 30,124 |
| Memory bits | 4,096 |
| Synthesis | Successful |

基线中仅 `pmem[512][8]` 以带旁路方式进入存储；接收 `mem`、SNMP `rxb/txb/ttb`
和 615A `img/mbuf` 仍产生大量组合逻辑。

## 3. 实现内容

### 3.1 管理帧接收缓存

- `afdx_mgmt_path.mem[2048][8]` 改为双 bank `1024 x 8` 同步读。
- 固定 42 字节首部在捕获阶段锁存，避免整块组合读。
- 请求载荷按 `R_START/R_FEED` 地址预取，送入 SNMP/RTC/615A 引擎。

### 3.2 管理响应缓存

- `pmem[512][8]` 改为同步读。
- UDP 校验、CRC 预计算和最终 MAC 发送三个阶段分别预取。
- 消除了综合报告中的 `pmem` 未推断 RAM/异步读旁路。

### 3.3 SNMP Agent

- `rxb[256][8]`：同步读 RAM；解析前顺序搬入 64 字节短报文视图。
- `txb[256][8]`：M4K 单写口；响应按 HEAD/VER/COMM/PDU/RID/TAIL/OID 分段逐字节生成。
- `ttb[128][8]`：M4K 单写口；90 字节 Trap 逐字节生成。
- 分段组包消除了 `rid_len → 全局动态位置 → 字节选择 → RAM` 的长组合路径。

### 3.4 ARINC 615A

- `mbuf[520][8]`：同步读 RAM，报文头用首 3 字节标量锁存，DATA 块同步预取。
- `img[1024][8]`：M4K 同步读写；ACTIVATE 从镜像 RAM 顺序回读并重算 CRC，
  不再仅依赖写入时累计值。

## 4. 回归结果

每次模块改动后均执行：

```powershell
python scripts\check_multidriver.py test.srcs\sources_1\afdx
powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
```

最终结果：多驱动检查 PASS，15/15 用例 PASS。

- SNMP：16/16 响应逐字节一致，90 字节 Trap 一致。
- SNMP 网络端到端：3/3 响应一致。
- RTC：装载/运行/查询 PASS。
- 615A：6/6 响应；镜像长度 612，CRC `0x3DF38E2D`，与基线一致。
- AFDX 收发、冗余、错误注入、吞吐/时延用例保持 PASS。

## 5. 最终综合与实现

约束：`afdx_top.sdc`，主时钟 50 MHz（20 ns）。

| 项目 | 结果 |
|---|---:|
| Synthesis | Successful，0 error |
| LUT | **12,574 / 136,160（9%）** |
| FF | **3,171 / 136,160（2%）** |
| 内嵌存储 | **54,336 bit / 16 块（1%）** |
| DSP | 0 / 48 |
| 引脚 | 22 / 339 |
| Implementation | Successful |
| WNS | **+0.902 ns** |
| 约束频率等效 Fmax | **约 52.36 MHz** |
| 布线错误 | **0** |

eLinx 的 `Actual Fmax` 字段显示 `N/A`；等效 Fmax 由
`1/(20 ns − 0.902 ns)` 计算，正式结论以正 WNS 为准。

当前配置为 4 TX / 8 RX，因此管理通道 RAM 化后只有 16 个存储块；
容量方案中的 30–60 块预估包含后续 S3 的 4096 接收 VL 状态表。

## 6. 归档报告

- `doc/refactor_baseline/S1b_mgmt_path_S0_synth.map.summary`
- `doc/refactor_baseline/S1b_mgmt_path_S0_synth.map.rpt`
- `doc/refactor_baseline/S1b_final_synth.map.summary`
- `doc/refactor_baseline/S1b_final_synth.map.rpt`
- `doc/refactor_baseline/S1b_final_synth.utilization.rpt`
- `doc/refactor_baseline/S1b_final_impl.utilization.rpt`
- `doc/refactor_baseline/S1b_final_impl.slack.rpt`
- `doc/refactor_baseline/S1b_final_impl.route_status.rpt`

## 7. 遗留问题

- 下一阶段进入 S2：TX VL 表 RAM、4 VL/拍扫描器、就绪 FIFO、128 发送 VL。
- S3 再处理 RX RM 状态 RAM、VLID 二分查找和 4096 接收 VL。
- 管理通道当前仍与 SNMP 单 varbind/短格式约束一致，GetBulk/多 varbind 未扩展。
