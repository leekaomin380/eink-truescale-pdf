/* wechat_extractor.js — 微信公众号正文抽取器（WKWebView 端上运行版）
 *
 * 契约：globalThis.readislandExtract(doc, url) → { ok, outcome, title, author, date, site, markdown, reason }
 * 不依赖任何 npm 包，只用浏览器标准 DOM API。
 * 复刻 server/readisland_delivery/content_extract.py 的 classify_and_extract 判定逻辑。
 */

(function () {
  'use strict';

  var MIN_BODY_CHARS = 200;

  // 当前文档的基地址，由 extract() 在入口写入。
  // walk() 是递归的纯函数，不便逐层透传，故用模块级变量 —— 每次 extract 都重置。
  var docBaseURL = '';

  // 把可能的相对地址补成绝对地址。
  // 不用 new URL()：WKWebView 里可用，但本文件也在 node + jsdom 下做离线测试，
  // 且旧 WebKit 对畸形 base 会抛异常。手写规则更可控，失败时返回空串（丢弃该图）。
  function absolutize(src, base) {
    if (!src) return '';
    if (/^(https?:|data:)/i.test(src)) return src;
    if (/^\/\//.test(src)) return 'https:' + src;          // 协议相对
    if (!base) return '';                                   // 无基地址，无法解析
    try {
      var m = base.match(/^(https?:\/\/[^\/]+)(\/.*?)?$/i);
      if (!m) return '';
      var origin = m[1];
      if (src.charAt(0) === '/') return origin + src;        // 根相对
      var dir = (m[2] || '/').replace(/[^\/]*$/, '');       // 去掉文件名，保留目录
      return origin + dir + src;                            // 目录相对
    } catch (e) { return ''; }
  }

  function toMarkdown(el) {
    if (!el) return '';
    var parts = [];
    walk(el, parts);
    return parts.join('').replace(/\n{3,}/g, '\n\n').trim();
  }

  function walk(node, parts) {
    if (node.nodeType === 3) {
      var t = node.textContent;
      if (t) parts.push(t);
      return;
    }
    if (node.nodeType !== 1) return;

    var tag = node.tagName;

    // 【2026-07-19 审计 F-1】SCRIPT / STYLE / NOSCRIPT 的子节点是【代码文本】，不是正文。
    //
    // 本文件头声明「复刻 content_extract.py 的 classify_and_extract」，而服务端在
    // extract_html 入口即 strip_scripts —— 复刻时漏了这一步。默认分支是 renderChildren，
    // 于是这些标签的源码被当成 3 型文本节点原样推进 markdown。
    //
    // 实测（node 驱动本函数，最小 DOM 桩）：
    //   <p>正文一</p><script>var s=…</script><style>.x{color:red}</style><p>正文二</p>
    //   → "正文一。\n\nvar s=….x{color:red}\n\n正文二。"
    //
    // 微信排版工具（135editor / 秀米）常在正文容器内嵌 <style>，故这不是理论风险。
    // 注意：服务端 strip_scripts 刻意【不】剥 style（trafilatura 自己会丢掉它），
    // 那条依据【不适用于本文件】—— 这里没有解析库兜着，只有这个 walker。
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') return;

    // 【2026-07-30 通用网页支持】NAV / HEADER / FOOTER / ASIDE 是页面骨架，不是正文。
    // 公众号正文容器（#js_content）内不出现这些标签，故对既有路径零影响；
    // 而通用博客站的 article/main 里常包着面包屑、站内导航、订阅区、相关文章，
    // 不剥掉就会把「Home Archive Search Tags Subscribe」之类混进正文。
    if (tag === 'NAV' || tag === 'HEADER' || tag === 'FOOTER' || tag === 'ASIDE') return;

    if (tag === 'BR') { parts.push('\n'); return; }
    if (tag === 'HR') { parts.push('\n---\n'); return; }

    if (tag === 'H1' || tag === 'H2' || tag === 'H3' || tag === 'H4' || tag === 'H5' || tag === 'H6') {
      parts.push('\n\n');
      var level = parseInt(tag[1], 10);
      for (var i = 0; i < level; i++) parts.push('#');
      parts.push(' ');
      renderChildren(node, parts);
      parts.push('\n\n');
      return;
    }

    if (tag === 'P' || tag === 'DIV' || tag === 'SECTION' || tag === 'ARTICLE') {
      parts.push('\n\n');
      renderChildren(node, parts);
      parts.push('\n\n');
      return;
    }

    if (tag === 'BLOCKQUOTE') {
      var inner = [];
      renderChildren(node, inner);
      var lines = inner.join('').split('\n');
      for (var li = 0; li < lines.length; li++) {
        parts.push('> ' + lines[li] + '\n');
      }
      parts.push('\n');
      return;
    }

    if (tag === 'UL' || tag === 'OL') {
      parts.push('\n');
      var idx = 1;
      var children = node.children;
      for (var ci = 0; ci < children.length; ci++) {
        if (children[ci].tagName === 'LI') {
          var prefix = tag === 'OL' ? (idx++ + '. ') : '- ';
          var liContent = [];
          renderChildren(children[ci], liContent);
          parts.push(prefix + liContent.join('').trim() + '\n');
        }
      }
      parts.push('\n');
      return;
    }

    if (tag === 'PRE') {
      parts.push('\n```\n');
      renderChildren(node, parts);
      parts.push('\n```\n\n');
      return;
    }

    if (tag === 'A') {
      var href = node.getAttribute('href');
      var linkText = [];
      renderChildren(node, linkText);
      var text = linkText.join('');
      if (href && text) {
        parts.push('[' + text + '](' + href + ')');
      } else {
        parts.push(text);
      }
      return;
    }

    if (tag === 'IMG') {
      // 微信是【懒加载】的: 内容图的真实 URL 在 data-src,src 常为空;还有完全裸的
      // <img>(一个属性都没有)当占位。实测真实文章 13 张图: 仅 4 张有非空 src、
      // 5 张有 data-src、其余是裸标签。只读 src 会漏掉大部分内容图。
      var src = node.getAttribute('data-src') || node.getAttribute('src') || '';
      if (!src) return;   // 裸 <img> 不产出 —— 否则正文里出现 ![]() 噪声,直接显示在电纸书上
      // 【2026-07-30】相对地址必须绝对化：ImageInliner 只认 https?:// 开头的
      // markdown 图片，相对路径会被整条跳过 —— 图片静默消失，PDF 里只剩文字。
      // 实测 lilianweng.github.io 一篇 36 张图的文章，抽取后一张都没进 PDF。
      // 公众号图（mmbiz.qpic.cn）本就是绝对地址，此处对既有路径零影响。
      src = absolutize(src, docBaseURL);
      if (!src) return;
      var alt = node.getAttribute('alt') || '';
      parts.push('![' + alt + '](' + src + ')');
      return;
    }

    if (tag === 'STRONG' || tag === 'B') {
      parts.push('**');
      renderChildren(node, parts);
      parts.push('**');
      return;
    }

    if (tag === 'EM' || tag === 'I') {
      parts.push('*');
      renderChildren(node, parts);
      parts.push('*');
      return;
    }

    if (tag === 'CODE') {
      parts.push('`');
      renderChildren(node, parts);
      parts.push('`');
      return;
    }

    if (tag === 'SUP') {
      parts.push('^(');
      renderChildren(node, parts);
      parts.push(')');
      return;
    }

    if (tag === 'SPAN' || tag === 'SMALL' || tag === 'ABBR' || tag === 'TIME' || tag === 'LABEL') {
      renderChildren(node, parts);
      return;
    }

    renderChildren(node, parts);
  }

  function renderChildren(node, parts) {
    var children = node.childNodes;
    for (var i = 0; i < children.length; i++) {
      walk(children[i], parts);
    }
  }

  function extractTitle(doc) {
    var og = doc.querySelector('meta[property="og:title"]');
    if (og) {
      var v = og.getAttribute('content');
      if (v) return v.trim();
    }
    var t = doc.querySelector('title');
    if (t) return t.textContent.trim();
    var h1 = doc.querySelector('h1');
    if (h1) return h1.textContent.trim();
    return '';
  }

  function extractMeta(doc) {
    var author = null;
    var date = null;
    var site = null;

    var authorEl = doc.querySelector('meta[property="og:article:author"]');
    if (!authorEl) authorEl = doc.querySelector('meta[name="author"]');
    if (authorEl) author = authorEl.getAttribute('content') || null;

    var dateEl = doc.querySelector('meta[property="og:article:published_time"]');
    if (!dateEl) dateEl = doc.querySelector('meta[name="publish_time"]');
    if (!dateEl) dateEl = doc.querySelector('time[datetime]');
    if (dateEl) {
      date = dateEl.getAttribute('content') || dateEl.getAttribute('datetime') || null;
    }

    var siteEl = doc.querySelector('meta[property="og:site_name"]');
    if (siteEl) site = siteEl.getAttribute('content') || null;

    return { author: author, date: date, site: site };
  }

  function classify(html) {
    var riskGrayKeywords = [
      'verify.mp.weixin.qq.com',
      'global.location.replace',
      '环境异常',
      '访问过于频繁',
      '当前环境异常'
    ];
    for (var i = 0; i < riskGrayKeywords.length; i++) {
      if (html.indexOf(riskGrayKeywords[i]) !== -1) return 'RISK_GRAY';
    }

    var contentGoneKeywords = [
      '该内容已被发布者删除',
      '此内容因违规无法查看',
      '该账号已被屏蔽',
      '该内容已被发布者删除，无法查看'
    ];
    for (var j = 0; j < contentGoneKeywords.length; j++) {
      if (html.indexOf(contentGoneKeywords[j]) !== -1) return 'CONTENT_GONE';
    }

    if (html.indexOf('js_content') === -1 && html.indexOf('rich_media_content') === -1) {
      // 【2026-07-30】非公众号页面走到这里属正常，不该一律报「结构缺失」。
      // 区分两种失败，因为对用户的建议完全不同：
      //   NEEDS_JS —— 页面骨架在但正文是 JS 渲染的。WKWebView 为隐私与速度
      //               屏蔽了全部网络请求（实测 1343ms → 225ms），故拿不到正文。
      //               这类站点本工具无解，应建议用户改用「粘贴文本」。
      //   STRUCT_MISSING —— 连骨架都没有，多半不是文章页（首页/列表页/登录墙）。
      var hasShell = html.indexOf('<article') !== -1 || html.indexOf('<main') !== -1 ||
                     html.indexOf('role="main"') !== -1;
      return hasShell ? 'NEEDS_JS' : 'STRUCT_MISSING';
    }

    return 'EXTRACT_EMPTY';
  }

  // 通用网页的正文容器候选，按【语义精确度】降序。
  // 不按「文本最长」排序：`#content` / `.content` 常把侧栏与评论一起圈进来，
  // 长度更长但质量更差。故先按语义优先级取，只要文本量够就采用。
  var GENERIC_SELECTORS = [
    'article',
    '[role="main"]',
    'main',
    '.post-content', '.entry-content', '.article-content', '.post-body',
    '.markdown-body',
    '#content', '.content'
  ];

  // 选定正文容器。
  //
  // 【顺序即契约】微信选择器必须最先尝试且行为不变 —— 那条路径针对单一站点调过
  // （反爬识别、data-src 懒加载图、135editor 内嵌 style），是本项目最可靠的一条，
  // 不能因为新增通用支持而被通用规则抢走。
  //
  // 通用抽取【永远做不到 100%】：重 JS 渲染的站点在 WKWebView 断网模式下拿不到
  // 正文，付费墙站点抽到的是摘要。故失败时必须如实报错，不可假装成功。
  function pickContainer(doc) {
    var wx = doc.querySelector('#js_content') || doc.querySelector('.rich_media_content');
    if (wx) return { el: wx, via: 'wechat' };

    for (var i = 0; i < GENERIC_SELECTORS.length; i++) {
      var nodes = doc.querySelectorAll(GENERIC_SELECTORS[i]);
      // 同一选择器命中多个时取文本最多的那个（如多个 <article> 里正文那篇最长）
      var best = null, bestLen = 0;
      for (var k = 0; k < nodes.length; k++) {
        var t = (nodes[k].textContent || '').replace(/\s+/g, '').length;
        if (t > bestLen) { bestLen = t; best = nodes[k]; }
      }
      if (best && bestLen >= MIN_BODY_CHARS) return { el: best, via: 'generic' };
    }
    return { el: null, via: 'none' };
  }

  function extract(doc, url) {
    docBaseURL = url || '';
    if (!doc) {
      return {
        ok: false,
        outcome: 'STRUCT_MISSING',
        title: '',
        author: null,
        date: null,
        site: null,
        markdown: '',
        reason: 'no_doc'
      };
    }

    var picked = pickContainer(doc);
    var container = picked.el;

    if (!container) {
      var rawHtml = doc.documentElement ? doc.documentElement.outerHTML : '';
      var outcome = classify(rawHtml);
      return {
        ok: false,
        outcome: outcome,
        title: '',
        author: null,
        date: null,
        site: null,
        markdown: '',
        reason: outcome
      };
    }

    var md = toMarkdown(container);

    if (md.length >= MIN_BODY_CHARS) {
      var meta = extractMeta(doc);
      return {
        ok: true,
        outcome: 'OK',
        title: extractTitle(doc),
        author: meta.author,
        date: meta.date,
        site: meta.site,
        markdown: md,
        via: picked.via,
        reason: ''
      };
    }

    var rawHtml = doc.documentElement ? doc.documentElement.outerHTML : '';
    var outcome = classify(rawHtml);
    return {
      ok: false,
      outcome: outcome,
      title: '',
      author: null,
      date: null,
      site: null,
      markdown: '',
      reason: outcome
    };
  }

  globalThis.readislandExtract = extract;
})();
