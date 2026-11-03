from docx import Document
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.enum.text import WD_ALIGN_PARAGRAPH

path = 'doc/AFDX端系统技术文档.docx'
doc = Document(path)
for section in doc.sections:
    footer = section.footer
    p = footer.paragraphs[0]
    for child in list(p._p):
        p._p.remove(child)
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.add_run('AFDX 端系统技术文档  |  ')
    run = OxmlElement('w:r')
    begin = OxmlElement('w:fldChar'); begin.set(qn('w:fldCharType'), 'begin')
    instr = OxmlElement('w:instrText'); instr.set(qn('xml:space'), 'preserve'); instr.text = ' PAGE '
    separate = OxmlElement('w:fldChar'); separate.set(qn('w:fldCharType'), 'separate')
    value_run = OxmlElement('w:r')
    value = OxmlElement('w:t'); value.text = '1'; value_run.append(value)
    end = OxmlElement('w:fldChar'); end.set(qn('w:fldCharType'), 'end')
    for node in (begin, instr, separate): run.append(node)
    p._p.append(run); p._p.append(value_run)
    end_run = OxmlElement('w:r'); end_run.append(end); p._p.append(end_run)

settings = doc.settings.element
update = settings.find(qn('w:updateFields'))
if update is None:
    update = OxmlElement('w:updateFields')
    settings.append(update)
update.set(qn('w:val'), 'true')
doc.save(path)
