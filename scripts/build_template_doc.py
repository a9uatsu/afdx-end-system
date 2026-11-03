from pathlib import Path
from docx import Document
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

root=Path(__file__).resolve().parents[1]
template=Path(r'E:\浏览器\2658aa94-81d0-454c-b2ac-fc040ff2c01a.docx')
out=root/'doc'/'AFDX技术文档_模板版.docx'
arch=root/'doc'/'afdx_architecture.png'
doc=Document(template)
body=doc._element.body
for child in list(body):
    if child.tag != qn('w:sectPr'):
        body.remove(child)

def para(text='',style='Normal',boldlead=None):
    p=doc.add_paragraph(style=style)
    if boldlead and text.startswith(boldlead):
        p.add_run(boldlead).bold=True; p.add_run(text[len(boldlead):])
    else: p.add_run(text)
    return p

def heading(text,level=1): return para(text,f'Heading {level}')
def table(headers,rows):
    t=doc.add_table(rows=1,cols=len(headers))
    for c,h in zip(t.rows[0].cells,headers):
        c.text=h
        for r in c.paragraphs[0].runs: r.bold=True; r.font.color.rgb=RGBColor(31,78,121)
    trPr=t.rows[0]._tr.get_or_add_trPr(); rep=OxmlElement('w:tblHeader'); rep.set(qn('w:val'),'true'); trPr.append(rep)
    for row in rows:
        cells=t.add_row().cells
        for c,v in zip(cells,row): c.text=str(v)
    doc.add_paragraph()
    return t

title=para('AFDX 端系统技术文档','Heading 2'); title.alignment=WD_ALIGN_PARAGRAPH.CENTER
para('基于 FPGA 的航空电子全双工交换式以太网端系统设计')
heading('摘要',2)
para('本文介绍一套基于 FPGA 的 AFDX 端系统设计。系统以 8 位以太网 MAC 字节流为接口，实现 Ethernet、IPv4、UDP 帧处理，发送虚拟链路配置与 BAG 调度，接收冗余管理和完整性检查，并集成 SNMP v2c、RTC 与 ARINC 615A 加载子集。工程面向 EQ6HL130 / CSG484_H 器件，采用 Verilog-2001，顶层模块为 AFDX_top。设计支持 128 条发送 VL 和 4096 个接收 VLID；ModelSim 仿真及 eLinx 综合实现结果用于验证功能与资源时序表现。')

heading('第一部分  产品介绍',1)
heading('1.1 产品概述',2)
para('AFDX 端系统是连接应用数据与航空电子交换网络的通信端点。本设计将 VL 参数、定时调度、帧封装、网络管理与冗余接收功能集成于 FPGA 逻辑中，提供可综合、可仿真的端系统原型。')
heading('1.2 应用场景',2)
para('系统面向具有确定性传输和链路冗余需求的航空电子网络研究与教学验证，可用于观察 VL 调度、序列号管理、帧完整性检查和管理报文处理流程。')
heading('1.3 主要功能特点',2)
table(['功能类别','设计内容'],[
('确定性发送','按 VL 独立配置 BAG，采用就绪检测与轮询仲裁'),
('协议处理','Ethernet II、IPv4、UDP、VLID、SN、校验和与 FCS'),
('高完整性接收','帧校验、冗余副本去重、失序恢复、过期丢弃和故障窗口'),
('网络管理','SNMP v2c Get / GetNext / Set / Trap'),
('时钟与加载','RTC 时间装载/查询，ARINC 615A WRQ/DATA/ACTIVATE/READ 子集')])
heading('1.4 主要技术指标',2)
table(['指标','设计/验证结果'],[
('链路速率目标','100 Mbps；仿真吞吐用例约 129.6 Mbps'),
('有效载荷','最大 1471 字节，含 VLID 与 SN'),
('帧长','64 至 1518 字节范围内；发送参考校验帧为 64 至 1517 字节'),
('发送/接收容量','128 TX VL / 4096 RX VLID'),
('时序','50 MHz 约束下报告最小 slack +1.411 ns')])
heading('1.5 设计创新与工程特点',2)
para('发送 VL 表与调度路径采用分 bank 扫描和就绪队列，兼顾容量扩展与仲裁吞吐。接收 VLID 状态通过 RAM 化结构和查找/读改写流程降低大容量状态表的逻辑开销。BAG 计时以实际帧起始为基准重装，避免发送准备阶段造成间隔不足。')

heading('第二部分  系统组成与设计说明',1)
heading('2.1 系统组成',2)
para('系统由赛题模板顶层、发送子系统、接收子系统、冗余管理模块和网络管理通道组成。下图展示控制配置、发送数据流、接收数据流及管理接口之间的关系。')
p=doc.add_paragraph(); p.alignment=WD_ALIGN_PARAGRAPH.CENTER; p.add_run().add_picture(str(arch),width=Inches(6.6))
cap=para('图 1  AFDX 端系统架构与数据流'); cap.alignment=WD_ALIGN_PARAGRAPH.CENTER
heading('2.2 硬件系统设计',2)
para('目标器件为 EQ6HL130 / CSG484_H，设计采用 50 MHz 单时钟域和同步高有效复位。顶层提供 8 位 TX/RX 数据、valid 与 ready 信号，内部以字节为单位处理帧。双网口模式可将发送帧复制到 A/B 两路；接收端当前采用共享解析通路。')
heading('2.3 软件与 RTL 模块设计',2)
table(['模块','职责'],[
('AFDX_top / afdx_es_core','模板接口、端系统集成及双网口控制'),
('afdx_vl_table / afdx_scheduler','发送 VL 配置、BAG 定时、后台扫描和轮询仲裁'),
('afdx_sn_gen / afdx_frame_tx','序列号生成、Ethernet/IP/UDP 帧组装及发送'),
('afdx_frame_rx / afdx_rx_path','帧缓存、格式校验、协议解析与载荷交付'),
('afdx_rm_rx','VLID 搜索、SN 判定、去重和完整性故障窗口'),
('afdx_mgmt_path / SNMP / RTC / 615A','管理报文分流、协议处理和响应封装'),
('afdx_checksum16 / afdx_crc32','IPv4/UDP 校验和及 Ethernet FCS')])
heading('2.4 协议数据流',2)
para('发送路径依次读取 VL 配置、判断 BAG 到期、仲裁授权、生成 SN、组装 Ethernet/IPv4/UDP 帧并计算校验和与 FCS，最后通过 MAC 字节流发送。接收路径捕获帧后检查长度、地址、填充和校验字段，再依据 VLID 与 SN 执行副本去重和完整性判定，接受的数据以 VLID、SN 和载荷形式交付。')
heading('2.5 帧格式与校验',2)
table(['字段','长度','说明'],[
('MAC 地址与 EtherType','14 B','目的/源 MAC 与 IPv4 类型'),('IPv4 头','20 B','IPv4 基本头及头校验和'),('UDP 头','8 B','源/目的端口、长度和 UDP 校验和'),('VLID 与 SN','3 B','16 位 VLID 与 8 位序列号'),('功能数据','0 至 1468 B','应用载荷'),('填充与 FCS','可变 + 4 B','满足最小帧长并附加 Ethernet CRC-32')])

heading('第三部分  功能实现',1)
heading('3.1 功能模块实现',2)
para('发送调度器为每条 VL 维护 BAG 到期状态，并在帧开始时重装计时。序列号在 1 至 255 间循环。接收冗余管理识别相同 SN 的重复副本，对合理前向跳变进行恢复并记录完整性错误，对过期帧及未知 VL 进行拒绝。错误窗口达到阈值后形成 VL 故障状态，供 SNMP 管理通道读取。')
heading('3.2 管理功能实现',2)
para('SNMP v2c 代理提供 Get、GetNext、Set 与 Trap，管理路径依据 UDP 端口 161 分流。RTC 通道通过端口 123 支持时间装载和查询。615A 加载器通过端口 10000 处理 WRQ、DATA、ACTIVATE 和 READ 子集，并维护镜像长度及 CRC。GetBulk、多 varbind 和完整 615A 标准会话尚未覆盖。')
heading('3.3 仿真验证',2)
para('采用 ModelSim 对 RTL 和测试平台进行常规编译与仿真，覆盖发送、接收、容量、冗余管理、SNMP、RTC、615A 及性能功能。仿真输出与独立参考结果核对，本次回归结果通过。')
heading('3.4 综合与实现结果',2)
table(['资源/时序项目','结果'],[
('LUT','14,059 / 136,160'),('FF','3,876 / 136,160'),('Memory','46 / 1,200'),('DSP','0 / 48'),('引脚','22 / 339'),('50 MHz 最小 slack','+1.411 ns'),('路由错误','0')])
para('上述数据来自工程现有 eLinx 综合、布局布线及时序报告。源码变更后应重新执行实现流程以确认结果对应当前版本。')
heading('3.5 功能成果与限制',2)
para('容量仿真覆盖 128 条发送 VL 与 4096 个接收 VLID；长稳测试运行 12,000 帧，未发现 BAG 违规或 VL 饥饿。当前应用数据源为确定性测试模式，未提供完整应用侧 FIFO/寄存器写入口；双网口接收解析仍共享通路，重叠副本能力可继续增强。')

heading('第四部分  总结',1)
para('本设计完成 AFDX 端系统主要发送、接收和管理功能，具备模板顶层接口、容量扩展结构、仿真验证材料及 FPGA 综合实现结果。后续工作包括扩展 SNMP GetBulk 与多 varbind、增加应用数据写入接口、完善双网口并行解析，以及补齐 615A 完整会话语义。')

heading('第五部分  参考资料',1)
para('1. 全国大学生嵌入式芯片与系统设计竞赛 2026 FPGA 创新设计赛道选题指南，中科亿海微，选题一。')
para('2. ARINC Specification 664 Part 7，航空电子全双工交换式以太网相关规范。')
para('3. IEEE 802.3，Ethernet 帧格式与 FCS 相关规范。')
para('4. RFC 768，User Datagram Protocol。')
para('5. RFC 791，Internet Protocol。')

# Consistent, readable typography while preserving template section geometry and base heading hierarchy.
for section in doc.sections:
    section.top_margin=Inches(0.8); section.bottom_margin=Inches(0.8)
for name,size,color in [('Normal',10.5,'263746'),('Heading 1',16,'1f4e79'),('Heading 2',13,'28708a')]:
    s=doc.styles[name]; s.font.name='Microsoft YaHei'; s.font.size=Pt(size); s.font.color.rgb=RGBColor.from_string(color); s._element.rPr.rFonts.set(qn('w:eastAsia'),'Microsoft YaHei')
doc.core_properties.author=''; doc.core_properties.last_modified_by=''; doc.core_properties.title='AFDX 端系统技术文档'
doc.save(out)
print(out)
