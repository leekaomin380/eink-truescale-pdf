import argparse
import json
import os
import subprocess
import re
import sys
from PIL import Image

GREEK = {
    'alpha':'α','beta':'β','gamma':'γ','delta':'δ','epsilon':'ε','zeta':'ζ','eta':'η',
    'theta':'θ','iota':'ι','kappa':'κ','lambda':'λ','mu':'μ','nu':'ν','xi':'ξ',
    'pi':'π','rho':'ρ','sigma':'σ','tau':'τ','upsilon':'υ','phi':'φ','chi':'χ',
    'psi':'ψ','omega':'ω','Delta':'Δ','Gamma':'Γ','Lambda':'Λ','Omega':'Ω',
    'Sigma':'Σ','Phi':'Φ','Psi':'Ψ','Theta':'Θ','times':'×','cdot':'·','pm':'±',
    'rightarrow':'→','leftarrow':'←','to':'→','approx':'≈','sim':'~','circ':'°',
}

def delatex(md):
    """把 PaddleOCR 输出的行内 LaTeX 转成 HTML 上下标 + Unicode 希腊字母。

    不这样做的话，$ G_{\\beta\\gamma} $ 经 pandoc→EPUB→typst 之后会退化成字面量
    '$ G_{} $'：希腊字母被吞、美元符与花括号泄漏给读者。本书满篇 Ca^2+ / GABA_A /
    Gβγ，这条不修等于内容损坏。
    """
    def conv(m):
        t = m.group(1)
        # 只摘掉命令名，保留其花括号内容——内容里可能还有嵌套的 ^{} / _{}，
        # 用 [^{}]* 去配会漏（如 \mathrm{Na^{+}}）。花括号在最后统一清掉。
        t = re.sub(r'\\(?:mathrm|mathit|text|mathbf|operatorname)\s*', '', t)
        t = re.sub(r'\\([A-Za-z]+)', lambda g: GREEK.get(g.group(1), g.group(1)), t)
        t = re.sub(r'\^\{([^{}]*)\}', r'<sup>\1</sup>', t)
        t = re.sub(r'_\{([^{}]*)\}', r'<sub>\1</sub>', t)
        t = re.sub(r'\^(\w)', r'<sup>\1</sup>', t)
        t = re.sub(r'_(\w)', r'<sub>\1</sub>', t)
        t = t.replace('{', '').replace('}', '').replace('\\', '')
        return t.strip()
    md = re.sub(r'\$\s*([^$\n]*?)\s*\$', conv, md)
    md = re.sub(r'\\([A-Za-z]+)', lambda g: GREEK.get(g.group(1), g.group(0)), md)
    return md


def is_outer_column(bbox, p_index):
    if isinstance(bbox, str): bbox = json.loads(bbox)
    cx = (bbox[0] + bbox[2]) / 2
    if p_index % 2 == 0: return cx > 745
    else: return cx < 417

def get_main_blocks(page_idx, blocks):
    res = []
    for b in blocks:
        if not is_outer_column(b.get('block_bbox'), page_idx):
            res.append(b)
    # 必须按 block_order（阅读顺序）排，而不是 JSON 数组顺序（block_id 序）——
    # 否则 mb[-1] / mb[0] 取到的不是版面上的首尾块，跨页断句会漏检。
    def _ord(b):
        o = b.get('block_order')
        return int(o) if str(o).isdigit() else 10**6
    res.sort(key=_ord)
    return res

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--json', required=True)
    parser.add_argument('--pdf', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()

    base_dir = os.path.dirname(os.path.abspath(__file__))
    epub_build_dir = os.path.join(base_dir, 'epub_build')
    imgs_dir = os.path.join(epub_build_dir, 'imgs')
    check_dir = os.path.join(base_dir, '_check')
    
    os.makedirs(imgs_dir, exist_ok=True)
    os.makedirs(check_dir, exist_ok=True)

    with open(args.json) as f:
        d = json.load(f)

    # 1. Image Cropping
    print("Cropping images...")
    images_to_crop = []
    for p, page in enumerate(d):
        for b in page['prunedResult']['parsing_res_list']:
            if b['block_label'] in ['image', 'chart']:
                bbox = b['block_bbox']
                if isinstance(bbox, str): bbox = json.loads(bbox)
                x = int(bbox[0] * 2.777778)
                y = int(bbox[1] * 2.777778)
                w = int((bbox[2] - bbox[0]) * 2.777778)
                h = int((bbox[3] - bbox[1]) * 2.777778)
                out_name = f'img_in_{b['block_label']}_box_{int(bbox[0])}_{int(bbox[1])}_{int(bbox[2])}_{int(bbox[3])}.jpg'
                images_to_crop.append((p+1, x, y, w, h, out_name))
                
    for (p_num, x, y, w, h, out_name) in images_to_crop:
        out_path = os.path.join(imgs_dir, out_name)
        if not os.path.exists(out_path):
            cmd = ['pdftoppm', '-r', '400', '-x', str(x), '-y', str(y), '-W', str(w), '-H', str(h), 
                   '-f', str(p_num), '-l', str(p_num), '-jpeg', '-jpegopt', 'quality=85', args.pdf, os.path.join(imgs_dir, out_name.replace('.jpg', ''))]
            subprocess.run(cmd, check=True)
            import glob
            actual_outs = glob.glob(os.path.join(imgs_dir, out_name.replace('.jpg', '-*.jpg')))
            if actual_outs:
                os.rename(actual_outs[0], out_path)
            subprocess.run(['sips', '-Z', '1200', out_path], check=True, stdout=subprocess.DEVNULL)
            # 真正转灰度：sips -m 只贴 ICC profile，不改采样格式；必须用 Pillow 落到单通道。
            from PIL import Image
            with Image.open(out_path) as _im:
                _im.convert('L').save(out_path, 'JPEG', quality=85)

    # 2. Visual Check
    print("Generating visual check images...")
    check_images = [
        (33, 'img_in_image_box_24_122_748_979.jpg'),
        (10, 'img_in_image_box_36_120_152_224.jpg'),
        (25, 'img_in_image_box_91_487_590_826.jpg')
    ]
    for p_num, img_name in check_images:
        check_out = os.path.join(check_dir, f'check_p{p_num}.jpg')
        if not os.path.exists(check_out):
            # Render full page
            full_pg_prefix = os.path.join(check_dir, f'full_p{p_num}')
            subprocess.run(['pdftoppm', '-r', '400', '-f', str(p_num), '-l', str(p_num), '-jpeg', args.pdf, full_pg_prefix], check=True)
            full_pg_img = full_pg_prefix + f'-{p_num}.jpg'
            
            crop_img = os.path.join(imgs_dir, img_name)
            if os.path.exists(full_pg_img) and os.path.exists(crop_img):
                img1 = Image.open(full_pg_img)
                img2 = Image.open(crop_img)
                dst = Image.new('RGB', (img1.width + img2.width, max(img1.height, img2.height)))
                dst.paste(img1, (0, 0))
                dst.paste(img2, (img1.width, 0))
                dst.save(check_out)
                os.remove(full_pg_img)

    # 3. Process Defect A & B and 5
    page_mds = []
    merges = []
    end_chars = tuple("。？！：\"》）")
    for p in range(len(d) - 1):
        vb_p = [b for b in d[p]['prunedResult']['parsing_res_list'] if b['block_label'] not in ['header', 'number', 'footer', 'vision_footnote', 'reference_content']]
        vb_n = [b for b in d[p+1]['prunedResult']['parsing_res_list'] if b['block_label'] not in ['header', 'number', 'footer', 'vision_footnote', 'reference_content']]
        mb_p = get_main_blocks(p, vb_p)
        mb_n = get_main_blocks(p+1, vb_n)
        if not mb_p or not mb_n: continue
        t1_cands = [b for b in mb_p if b['block_label'] == 'text' and b.get('block_content','').strip()]
        t2_cands = [b for b in mb_n if b['block_label'] in ('text','paragraph_title','doc_title','figure_title')
                    and b.get('block_content','').strip()]
        if not t1_cands or not t2_cands: continue
        t1_block = t1_cands[-1]
        t2_block = t2_cands[0]
        if t1_block['block_label'] == 'text':
            txt = t1_block.get('block_content', '').strip()
            if txt and not txt.endswith(end_chars):
                if t2_block['block_label'] not in ['paragraph_title', 'doc_title', 'figure_title']:
                    merges.append({'p': p, 't1_text': txt, 't2_text': t2_block.get('block_content', '').strip()})

    for p, page in enumerate(d):
        md = page['markdown']['text']
        images = [b for b in page['prunedResult']['parsing_res_list'] if b.get('block_label') in ['image', 'chart']]
        
        group_to_blocks = {}
        for b in page['prunedResult']['parsing_res_list']:
            g = b.get('group_id')
            if g is not None:
                group_to_blocks.setdefault(g, []).append(b)

        outer_blocks = []
        for b in page['prunedResult']['parsing_res_list']:
            if b.get('block_label') not in ['text', 'paragraph_title', 'figure_title', 'vision_footnote']: continue
            bbox = b.get('block_bbox')
            if isinstance(bbox, str): bbox = json.loads(bbox)
            
            if is_outer_column(bbox, p):
                text = b.get('block_content', '')
                if text == '':
                    g = b.get('group_id')
                    siblings = group_to_blocks.get(g, [])
                    non_empty = [s for s in siblings if s.get('block_content')]
                    if len(non_empty) == 1:
                        mb = non_empty[0]
                        parts = mb['block_content'].split('\n\n')
                        if len(parts) >= 2:
                            if b.get('block_order', 999) > mb.get('block_order', 999): text = parts[1]
                            else: text = parts[0]
                
                if text:
                    outer_blocks.append({'bbox': bbox, 'text': text, 'cy': (bbox[1] + bbox[3]) / 2, 'y0': bbox[1], 'label': b.get('block_label')})

        for ob in outer_blocks:
            t = ob['text']
            # 优先整行删掉「任意级别标题 + 该文本」，避免留下孤儿 # 前缀
            md2 = re.sub(r'(?m)^[ \t]*#{1,6}[ \t]*' + re.escape(t) + r'[ \t]*$', '', md, count=1)
            if md2 != md:
                md = md2
            else:
                md = md.replace(t, '', 1)
            
        md = re.sub(r'\n{3,}', '\n\n', md)
        
        image_captions = { id(img): [] for img in images }
        if images and outer_blocks:
            for ob in outer_blocks:
                best_img = min(images, key=lambda img: abs(ob['cy'] - ( (json.loads(img['block_bbox']) if isinstance(img['block_bbox'], str) else img['block_bbox'])[1] + (json.loads(img['block_bbox']) if isinstance(img['block_bbox'], str) else img['block_bbox'])[3] )/2))
                image_captions[id(best_img)].append(ob)
                
        for img in images:
            caps = image_captions[id(img)]
            if not caps: continue
            caps.sort(key=lambda x: x['y0'])
            
            formatted_caption = []
            for c in caps:
                t = c['text'].strip()
                # block_content 本身可能已含 markdown 标题标记（如 '##### 图6.30'），
                # 再加一层前缀就会产出 '##### ##### 图6.30'。
                if c['label'] == 'paragraph_title' and not t.startswith('#'):
                    t = '##### ' + t
                formatted_caption.append(t)
            cap_str = '\n\n'.join(formatted_caption)
            
            bbox = img.get('block_bbox')
            if isinstance(bbox, str): bbox = json.loads(bbox)
            img_filename = f"img_in_{img.get('block_label')}_box_{int(bbox[0])}_{int(bbox[1])}_{int(bbox[2])}_{int(bbox[3])}.jpg"
            
            pattern = rf'<div style="text-align: center;"><img src="imgs/{img_filename}".*?</div>'
            match = re.search(pattern, md)
            if match:
                full_tag = match.group(0)
                md = md.replace(full_tag, f"{full_tag}\n\n{cap_str}\n\n")

        page_mds.append(md)

    # 先把图片 div 规整成独立块，否则它会粘在正文句子中间，
    # 并让下面的跨页合并无法按块操作。
    IMGDIV = r'<div style="text-align: center;"><img[^>]*?/></div>'
    for i, pmd in enumerate(page_mds):
        pmd = re.sub(r'\s*(' + IMGDIV + r')\s*', r'\n\n\1\n\n', pmd)
        page_mds[i] = re.sub(r'\n{3,}', '\n\n', pmd).strip()

    def split_blocks(md):
        return [b for b in re.split(r'\n\s*\n', md) if b.strip()]

    def is_body(b):
        b = b.strip()
        return bool(b) and not b.startswith('#') and not b.startswith('<div')

    # 跨页段落合并：按块操作，而不是脆弱的整串 replace。
    # 关键副作用——把夹在断句中间的图片/图注挤出去：正文半句被接回上一页后，
    # 本页剩下的图片与图注自然落到合并后段落之后。
    merged_ok = merged_fail = 0
    for m in merges:
        p = m['p']
        def _norm(x):
            return re.sub(r'[\s*#>`_]+', '', x)
        t2_head = _norm(m['t2_text'])[:12]
        if not t2_head:
            continue
        nxt = split_blocks(page_mds[p + 1])
        idx = next((i for i, b in enumerate(nxt)
                    if is_body(b) and _norm(b).startswith(t2_head)), None)
        cur = split_blocks(page_mds[p])
        cidx = next((i for i in range(len(cur) - 1, -1, -1) if is_body(cur[i])), None)
        if idx is None or cidx is None:
            merged_fail += 1
            continue
        cur[cidx] = cur[cidx].rstrip() + nxt.pop(idx).lstrip()
        page_mds[p] = '\n\n'.join(cur)
        page_mds[p + 1] = '\n\n'.join(nxt)
        merged_ok += 1
    print(f"Cross-page merges: {merged_ok} ok / {merged_fail} failed (of {len(merges)} detected)")

    full_md = '\n\n'.join(page_mds)
    full_md = re.sub(r'\n{3,}', '\n\n', full_md)
    full_md = delatex(full_md)
    
    md_path = os.path.join(epub_build_dir, 'book.md')
    with open(md_path, 'w') as f:
        f.write("---\n")
        f.write("title: 神经科学——探索脑（第四版）第 6 章 神经递质系统\n")
        f.write("author: Mark F. Bear / Barry W. Connors / Michael A. Paradiso\n")
        f.write("language: zh-CN\n")
        f.write("---\n\n")
        f.write(full_md)
        
    print("Building EPUB...")
    subprocess.run(['pandoc', 'book.md', '-o', args.out, '--toc', '--toc-depth=5'], cwd=epub_build_dir, check=True)

if __name__ == '__main__':
    main()
