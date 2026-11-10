# Website SEO — 2026-11-10

Canonical site: https://leekaomin380.github.io/eink-truescale-pdf/

## Implemented

- Four fully rendered, independently addressable pages: English `/`, Simplified Chinese `/zh/`, Traditional Chinese `/zh-hant/`, Japanese `/ja/`. Reading the HTML without JavaScript exposes the product, capabilities and FAQ.
- Each page has a distinct localized title and search description describing Mac → QUADERNO PDF transfer and EPUB/Markdown/text typesetting. Visible product labels and the first FAQ distinguish direct PDF transfer from text/EPUB typesetting; automatic PDF semantic reflow is not advertised as released.
- Each language keeps a self-referencing canonical and a reciprocal, absolute hreflang set, including `x-default`. HTML and XML sitemap alternates are checked against the same language configuration. Query strings used to check deployments are excluded from canonical URLs.
- WebSite, WebPage, SoftwareApplication and FAQPage JSON-LD describe the page and actual released application. Website modification date and App release date are separate. A PDF sample is no longer marked as an App screenshot. No invented ratings, reviews or awards were added.
- Open Graph and Twitter descriptions match the localized search descriptions; the existing 1200 × 630 social card remains available.
- First-screen photograph: JPEG fallback plus 640px/1024px WebP candidates with matching responsive preload and high fetch priority. Width/height prevent image layout shifts; CSS uses a content hash. Encodings preserve the selected brightened photograph.
- Sitemap is linked in page metadata and the footer. Existing language navigation uses normal HTML links. No language redirect requires a crawler to execute JavaScript or accept cookies.
- `python3 site/build.py --check` validates unique metadata, canonical/hreflang consistency, schema relationships, image candidates, local links, sitemap and generated output before every Pages deployment.
- `python3 site/check-live.py` checks public HTML, sitemap, key assets, response indexing headers and domain-root crawler rules after deployment. This is a publication/crawl check, not proof of indexing or a ranking score.

## GitHub Pages crawler configuration

The site is hosted under a path on `leekaomin380.github.io`. Crawlers read **https://leekaomin380.github.io/robots.txt**, not the project's `/eink-truescale-pdf/robots.txt`. The domain-root URL returned 404 during the audit; no root rule is currently preventing crawling. The project-local robots file is retained as a configuration template, not claimed as an effective domain-wide setting.

No changes were made to other repositories or other sites on the shared domain. An XML sitemap at the project URL can be submitted directly through an authenticated search console, without creating a root robots file.

## Search-console follow-up — not performed

There is no Search Console connector or verified owner session available in this task. No ownership token was invented, no sitemap submission was claimed, and no search-engine indexing was claimed.

When owner access is available:

1. Add/verify a URL-prefix property for `https://leekaomin380.github.io/eink-truescale-pdf/` in Google Search Console. Use the actual verification HTML file or meta token supplied by that account; then deploy it.
2. Submit `https://leekaomin380.github.io/eink-truescale-pdf/sitemap.xml`.
3. Inspect all four canonical URLs and request indexing where appropriate. Monitor indexed pages, queries, impressions, clicks and Core Web Vitals before deciding on further content changes.
4. Bing Webmaster Tools can be verified separately or imported from an actually verified Google property.

## Validation limits

JSON-LD syntax and site consistency are validated locally; this is not a claim that Google has certified rich-result eligibility. Software rich results may require actual ratings/reviews, and Google limits FAQ rich results primarily to authoritative government and health sites. The FAQ remains useful visible content; no special Google display is promised. Lab performance measurements are not field Core Web Vitals or a ranking guarantee.

## Primary references

- [Google: localized versions](https://developers.google.com/search/docs/specialty/international/localized-versions)
- [Google: supported metadata; keywords do not affect indexing/ranking](https://developers.google.com/search/docs/crawling-indexing/special-tags)
- [Google: SoftwareApplication structured data](https://developers.google.com/search/docs/appearance/structured-data/software-app)
- [Google: FAQ rich-result availability](https://developers.google.com/search/blog/2023/08/howto-faq-changes)
- [Google: root robots.txt location](https://developers.google.com/crawling/docs/robots-txt/create-robots-txt)
- [Google: build and submit a sitemap](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)
- [web.dev: LCP resource discovery and image priority](https://web.dev/articles/optimize-lcp)

## Local audit receipt

2026-11-10, Lighthouse 13.6.0, simulated mobile, local HTTP server, Simplified Chinese page: performance 99/100, accessibility 100/100, best-practices 100/100, seo 100/100. LCP 2.2 s, CLS 0. All four languages were checked with JavaScript disabled at 1440/900/390px: 12 combinations, readable content, complete images, four language links and no horizontal overflow. These are local lab results, not a public network or field-data score.
