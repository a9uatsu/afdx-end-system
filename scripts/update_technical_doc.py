from pathlib import Path
from docx import Document
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
DOCX = ROOT / 'doc' / 'AFDX端系统技术文档.docx'
ASSET = ROOT / 'doc' / 'afdx_architecture.png'

font_path = r'C:\Windows\Fonts\msyh.ttc'
font_bold_path = r'C:\Windows\Fonts\msyhbd.ttc'
font = ImageFont.truetype(font_path, 25)
font_small = ImageFont.truetype(font_path, 19)
font_title = ImageFont.truetype(font_bold_path, 31)
W, H = 1800, 1000
im = Image.new('RGB', (W, H), '#f5f8fc')
d = ImageDraw.Draw(im)

def box(x, y, w, h, title, body, fill, border='#c8d4e2'):
    d.rounded_rectangle((x,y,x+w,y+h), radius=18, fill=fill, outline=border, width=3)
    d.text((x+18,y+14), title, font=font, fill='#14283f')
    d.multiline_text((x+18,y+53), body, font=font_small, fill='#40536a', spacing=7)

def arrow(points, color='#53728f', width=5):
    d.line(points, fill=color, width=width, joint='curve')
    x1,y1=points[-2]; x2,y2=points[-1]
    import math
    a=math.atan2(y2-y1,x2-x1)
    p1=(x2-18*math.cos(a-0.55),y2-18*math.sin(a-0.55))
    p2=(x2-18*math.cos(a+0.55),y2-18*math.sin(a+0.55))
    d.polygon([(x2,y2),p1,p2],fill=color)

d.text((70,35),'AFDX 端系统架构与数据流',font=font_title,fill='#102a43')
d.text((72,82),'单时钟域 | 8 位 MAC 字节流 | 发送调度、接收完整性与网络管理',font=font_small,fill='#50657b')
d.rounded_rectangle((55,135,1745,935),radius=24,fill='#ffffff',outline='#d5dee8',width=3)
d.text((90,160),'系统控制与配置',font=font,fill='#276678')
box(90,210,300,130,'AFDX_top','模板接口与默认 VL 配置','#e6f3f3')
box(455,210,330,130,'发送 VL 表','MAC / IP / UDP / VLID\nBAG / 长度 / 使能','#e6f3f3')
box(850,210,340,130,'接收 VL 表与状态','4096 VLID 查找\nSN / 错误窗口 / 故障状态','#e6f3f3')
box(1255,210,390,130,'时钟与复位','50 MHz 单时钟域\n同步高有效复位','#e6f3f3')
arrow([(390,275),(455,275)]); arrow([(785,275),(850,275)]); arrow([(1190,275),(1255,275)])
d.text((90,390),'发送数据通路',font=font,fill='#276678')
box(90,440,270,150,'发送调度','BAG 倒计时\n轮询仲裁 / 就绪队列','#eaf1fb')
box(425,440,270,150,'序列号生成','每 VL 独立 SN\n1–255 循环','#eaf1fb')
box(760,440,350,150,'帧封装与校验','Ethernet / IPv4 / UDP\n校验和 / 填充 / FCS','#eaf1fb')
box(1180,440,440,150,'MAC TX 接口','8 位 data / valid / ready\n双网口可选同步复制','#eaf1fb')
arrow([(360,515),(425,515)]); arrow([(695,515),(760,515)]); arrow([(1110,515),(1180,515)])
d.text((90,635),'接收与管理通路',font=font,fill='#276678')
box(90,685,285,160,'MAC RX 接口','8 位字节流\n帧缓存与接收反压','#fff2e5')
box(430,685,330,160,'帧解析与完整性','长度 / 地址 / FCS\nIPv4 与 UDP 校验和','#fff2e5')
box(815,685,350,160,'冗余管理与交付','VLID 查找 / SN 判定\n去重 / 失序恢复 / 故障窗','#fff2e5')
box(1260,670,390,65,'SNMP v2c','Get / GetNext / Set / Trap','#f1ecfa')
box(1260,755,390,65,'RTC','时间装载 / 查询','#eef5e8')
box(1260,840,390,65,'ARINC 615A','加载子集','#eef5e8')
arrow([(375,765),(430,765)]); arrow([(760,765),(815,765)])
arrow([(1165,765),(1210,765)])
d.line([(1210,702),(1210,872)],fill='#53728f',width=5)
arrow([(1210,702),(1260,702)]); arrow([(1210,787),(1260,787)]); arrow([(1210,872),(1260,872)])
d.text((815,865),'应用数据交付：VLID / SN / Payload',font=font_small,fill='#40536a')
im.save(ASSET)

doc = Document(DOCX)
sec=doc.sections[0]
sec.top_margin=Inches(.72); sec.bottom_margin=Inches(.72)
sec.left_margin=Inches(.82); sec.right_margin=Inches(.82)
normal=doc.styles['Normal']; normal.font.name='Microsoft YaHei'; normal.font.size=Pt(10.5); normal.font.color.rgb=RGBColor(42,55,70)
normal._element.rPr.rFonts.set(qn('w:eastAsia'),'Microsoft YaHei')
for sname,size,color in [('Title',25,'17324D'),('Heading 1',16,'1E6174'),('Heading 2',12,'276678')]:
    st=doc.styles[sname]; st.font.name='Microsoft YaHei'; st.font.size=Pt(size); st.font.bold=True; st.font.color.rgb=RGBColor.from_string(color); st._element.rPr.rFonts.set(qn('w:eastAsia'),'Microsoft YaHei')

paras=list(doc.paragraphs)
for p in paras:
    if p.text.strip()=='```text':
        p.text=''
    if '发送配置 -> VL 表' in p.text:
        p.text=''
        p.alignment=WD_ALIGN_PARAGRAPH.CENTER
        p.add_run().add_picture(str(ASSET),width=Inches(6.7))
        cap=doc.add_paragraph('图 1  AFDX 端系统功能架构与数据流')
        cap.alignment=WD_ALIGN_PARAGRAPH.CENTER
        cap.runs[0].italic=True; cap.runs[0].font.size=Pt(9); cap.runs[0].font.color.rgb=RGBColor(90,105,120)
    if p.text.strip()=='```': p.text=''

# Replace detailed command and per-case listing with a concise standard workflow.
paras=list(doc.paragraphs)
start=next((i for i,p in enumerate(paras) if p.text.strip()=='### 7.1 环境与复现'),None)
end=next((i for i,p in enumerate(paras) if p.text.strip().startswith('长稳抖动和吞吐数据')),None)
if start is not None and end is not None:
    keep=paras[start]
    keep.text='### 7.1 仿真流程'
    for p in paras[start+1:end+1]:
        p._element.getparent().remove(p._element)
    keep.add_run('\n使用 ModelSim SE-64 10.7 和 Verilog-2001 兼容模式完成工程仿真。常规流程为：检查工程源文件及仿真顶层，编译 RTL 和测试平台，运行测试用例，查看 Transcript 的编译与仿真状态，并核对测试平台输出及参考结果。出现编译错误、仿真错误或结果不符时，根据日志定位对应模块后重新验证。\n\n本次仿真覆盖发送、接收、虚拟链路容量、冗余管理、SNMP、RTC、ARINC 615A 和性能等功能，整体结果通过。')

# Style all tables consistently.
for table in doc.tables:
    for row in table.rows:
        for cell in row.cells:
            for p in cell.paragraphs:
                p.paragraph_format.space_after=Pt(2)
                for r in p.runs:
                    r.font.name='Microsoft YaHei'; r.font.size=Pt(9)
                    r._element.get_or_add_rPr().rFonts.set(qn('w:eastAsia'),'Microsoft YaHei')
    if table.rows:
        trPr=table.rows[0]._tr.get_or_add_trPr(); rep=OxmlElement('w:tblHeader'); rep.set(qn('w:val'),'true'); trPr.append(rep)

# Footer with page numbers.
for section in doc.sections:
    fp=section.footer.paragraphs[0]; fp.alignment=WD_ALIGN_PARAGRAPH.CENTER
    fp.add_run('AFDX 端系统技术文档  |  ')
    fld=OxmlElement('w:fldSimple'); fld.set(qn('w:instr'),'PAGE'); fp._p.append(fld)

doc.core_properties.author=''
doc.core_properties.last_modified_by=''
doc.core_properties.title='AFDX 端系统技术文档'
doc.core_properties.subject='基于 FPGA 的 AFDX 端系统设计与验证'
doc.save(DOCX)
print(DOCX)
