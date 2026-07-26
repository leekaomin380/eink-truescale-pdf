/* wechat_extractor.js — 微信公众号正文抽取器（WKWebView 端上运行版）
 *
 * 契约：globalThis.readislandExtract(doc, url) → { ok, outcome, title, author, date, site, markdown, reason }
 * 不依赖任何 npm 包，只用浏览器标准 DOM API。
 * 复刻 server/readisland_delivery/content_extract.py 的 classify_and_extract 判定逻辑。
 */

(function () {
  'use strict';

  var MIN_BODY_CHARS = 200;

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
      return 'STRUCT_MISSING';
    }

    return 'EXTRACT_EMPTY';
  }

  function extract(doc, url) {
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

    var container = doc.querySelector('#js_content') || doc.querySelector('.rich_media_content');

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
