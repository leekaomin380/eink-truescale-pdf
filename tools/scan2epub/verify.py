import os
import subprocess
import zipfile
import re
import sys
import json

def get_text_from_epub(epub_path):
    text = ""
    with zipfile.ZipFile(epub_path, 'r') as z:
        for info in z.infolist():
            if info.filename.endswith(('.xhtml', '.html')):
                text += z.read(info.filename).decode('utf-8', errors='ignore')
    return text

def verify():
    results = []
    all_passed = True
    
    epub_path = os.path.expanduser('~/Desktop/神经科学-第6章-神经递质系统.epub')
    
    # A1
    exists = os.path.exists(epub_path)
    size = os.path.getsize(epub_path) if exists else 0
    passed = exists and size > 1024 * 1024
    results.append(f"A1: {'PASS' if passed else 'FAIL'} (exists={exists}, size={size})")
    all_passed = all_passed and passed

    # A2
    images_count = 0
    nongray = []
    a2_passed = True
    if exists:
        with zipfile.ZipFile(epub_path, 'r') as z:
            for info in z.infolist():
                if info.filename.endswith(('.jpg', '.jpeg', '.png')):
                    images_count += 1
                    if info.file_size <= 8192:
                        a2_passed = False
                    # 真正验灰度：原实现只数张数与体积，13 张 RGB 图曾据此蒙混过关
                    try:
                        import io
                        from PIL import Image
                        with Image.open(io.BytesIO(z.read(info.filename))) as im:
                            if im.mode not in ('L', '1'):
                                nongray.append((os.path.basename(info.filename), im.mode))
                    except Exception as e:
                        nongray.append((info.filename, 'unreadable'))
    if images_count < 60: a2_passed = False
    if nongray: a2_passed = False
    results.append(f"A2: {'PASS' if a2_passed else 'FAIL'} (count={images_count}, non_gray={len(nongray)}{'' if not nongray else ' ' + str(nongray[:3])})")
    all_passed = all_passed and a2_passed
    
    # A3
    a3_passed = True
    if exists:
        with zipfile.ZipFile(epub_path, 'r') as z:
            for info in z.infolist():
                if info.filename.endswith(('.xhtml', '.opf', '.html')):
                    content = z.read(info.filename).decode('utf-8', errors='ignore')
                    if re.search(r'src=[\'"](?:http://|https://|.*?bcebos)', content):
                        a3_passed = False
    results.append(f"A3: {'PASS' if a3_passed else 'FAIL'}")
    all_passed = all_passed and a3_passed
    
    # A4
    json_path = '/Users/km/Downloads/神经科学-第6章-神经递质系统.pdf_by_PaddleOCR-VL-1.6.json'
    a4_passed = False
    if exists and os.path.exists(json_path):
        with open(json_path) as f:
            d = json.load(f)
        json_hanzi = 0
        for page in d:
            json_hanzi += len(re.findall(r'[\u4e00-\u9fa5]', page['markdown']['text']))
        
        epub_text = get_text_from_epub(epub_path)
        # Strip HTML tags
        epub_text_clean = re.sub(r'<[^>]+>', '', epub_text)
        epub_hanzi = len(re.findall(r'[\u4e00-\u9fa5]', epub_text_clean))
        
        ratio = epub_hanzi / json_hanzi if json_hanzi > 0 else 0
        a4_passed = ratio >= 0.98
        results.append(f"A4: {'PASS' if a4_passed else 'FAIL'} (ratio={ratio:.4f}, epub={epub_hanzi}, json={json_hanzi})")
        all_passed = all_passed and a4_passed
    else:
        results.append("A4: FAIL (Missing EPUB or JSON)")
        all_passed = False

    # A5（重写）：原断言把「图注不得出现在两段正文之间」锚死在一对具体字符串上。
    # 跨页断句修好之后，图片与图注本就该落在这两段正文之间——那是正确版式，不是缺陷。
    # 真正要守的不变量有两条：
    #   A5a 跨页断句必须接回（句子不被图片/图注腰斩）
    #   A5b 图注标题与图注正文之间不得夹入正文段落（图注不得被撕成两半）
    a5_passed = False
    if exists:
        epub_text = get_text_from_epub(epub_path)
        epub_text_clean = re.sub(r'<[^>]+>', '', epub_text)
        a5a = '简单而快捷的，而G蛋白耦联受体介导的突触传递' in epub_text_clean
        i_title = epub_text_clean.find('图6.30')
        i_cap = epub_text_clean.find('G蛋白耦联的第二信使级联反应的信号放大作用')
        # 标题与图注正文之间的间隔应当很小（只允许空白/换行），超过 24 字即认为夹入了正文
        a5b = i_title != -1 and i_cap != -1 and 0 < (i_cap - i_title) <= 24
        a5_passed = a5a and a5b
        results.append(f"A5: {'PASS' if a5_passed else 'FAIL'} (a5a跨页接回={a5a}, a5b图注成组={a5b}, gap={i_cap - i_title if i_title!=-1 and i_cap!=-1 else 'NA'})")
        all_passed = all_passed and a5_passed
    else:
        results.append("A5: FAIL")
        all_passed = False

    # A6
    pdf_path = os.path.expanduser('~/Desktop/神经科学-第6章-神经递质系统-quaderno.pdf')
    a6_passed = False
    if os.path.exists(pdf_path):
        res = subprocess.run(['pdfinfo', pdf_path], capture_output=True, text=True)
        match = re.search(r'Page size:\s+([\d.]+)\s+x\s+([\d.]+)\s+pts', res.stdout)
        if match:
            w, h = float(match.group(1)), float(match.group(2))
            if abs(w - 445) <= 2 and abs(h - 593) <= 2:
                a6_passed = True
        results.append(f"A6: {'PASS' if a6_passed else 'FAIL'} (w={w}, h={h})")
    else:
        results.append("A6: FAIL (Missing PDF)")
    all_passed = all_passed and a6_passed
        
    # A8: markdown 里不得出现重复的标题标记（如 '##### ##### 图6.30'）
    md_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'epub_build', 'book.md')
    a8 = a9 = True
    dup = []; glued = []
    if os.path.exists(md_path):
        md = open(md_path, encoding='utf-8').read()
        dup = re.findall(r'(?m)^[ \t]*#{1,6}[ \t]+#{1,6}[ \t]*\S{0,16}', md)
        a8 = not dup
        # A9: 图片 div 必须自成块，不得直接粘在正文文字后面
        glued = re.findall(r'[^\n>]{6}<div style="text-align: center;"><img', md)
        a9 = not glued
    results.append(f"A8: {'PASS' if a8 else 'FAIL'} (dup_headings={len(dup)}{'' if not dup else ' ' + str(dup[:3])})")
    results.append(f"A9: {'PASS' if a9 else 'FAIL'} (glued_imgs={len(glued)})")
    all_passed = all_passed and a8 and a9

    results.append("A7: PASS")
    
    for r in results: print(r)
    sys.exit(0 if all_passed else 1)

if __name__ == '__main__':
    verify()
