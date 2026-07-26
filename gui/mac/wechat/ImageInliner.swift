import Foundation
import CoreGraphics
import ImageIO
import CoreImage

/// 把正文 markdown 里的远程图 URL 取下来、处理好、换成 data: URI。
///
/// 【为什么在端上取图，而不是让服务端取】
///   服务端 fetch 外部 URL = 同时打开 SSRF 攻击面 + 一条新的出站通道。而端上本来
///   就在用住宅 IP 抓 HTML（`fetchWechatHTML`），多取几张图是同一条已有通道。
///   **要阻断的是「服务端发起请求」，不是「图片」。**
///
/// 【为什么不用 canvas 截图】（原设计如此，实测后作废）
///   WKWebView 被我们全量阻断网络（隐私 + 反爬 + 顺带快 6 倍），图根本不会加载，
///   canvas 上什么都没有。而且微信图在 mmbiz.qpic.cn，与 mp.weixin.qq.com 跨域，
///   `toDataURL()` 会因画布被污染抛 SecurityError。**原生取图把这两个问题一起消掉。**
///
/// 【实测依据，2026-07-17 真实文章，全部不是设想】
///   · 微信 CDN **无防盗链**：裸请求（无 UA、无 Referer）即 200。不必伪造请求头。
///   · 微信是**懒加载**：内容图真实 URL 在 `data-src`，`src` 常为空（13 个 img 里
///     仅 4 个有非空 src、5 个有 data-src）。抽取器已处理，此处拿到的是真 URL。
///   · **图本来就小**：1080×1155 / 545×300 / 755×700 / 197×197 —— 全都小于电纸书屏
///     （约 1440×1920）。**「端上降采样」实测收益为 0**，且 `-Z` 那种"缩放到框内"
///     会把小图**放大**（197×197 → 1440×1440，7 倍），247KB 反而变成 378KB。
///     故：**只在超屏时缩，绝不放大。**
///   · **灰度不是稳赢**：182KB 的 PNG → 80KB（大赚），但 31KB 的 JPEG → 47KB、
///     1.2KB 的小 PNG → 6.3KB（大 5 倍）。故：**处理后比原图大，就用原图。**
///   · 总载荷：4 张图原样 247KB / 灰度后 157KB → base64 后总计约 215–335KB，
///     而现在【不带图】发的原始 HTML 是 3060KB。**带图之后反而小 9–14 倍。**
enum ImageInliner {

    /// 灾难护栏，**不是**屏幕适配。
    ///
    /// 【为什么不按屏幕尺寸缩图 —— 2026-07-17 高明纠正，且实测支持】
    ///   我本打算按"电纸书屏宽"缩图，**错在两处**：
    ///   ① **发送端不该替接收端决定分辨率。** 实测该用户已有【两台不同的】文石
    ///      （`delivery_events.model` 里 P6 与 Tango 并存），按其中一台硬编码，
    ///      另一台就是错的。而设备只会越来越杂。
    ///   ② **根本不需要缩。** 微信原生就发 1080px，比多数文石屏（1404–1872px）
    ///      **还窄**；再缩只会让大屏更糊，省下的字节买不来这个损失。
    ///      而 EPUB 里那条 `img{max-width:100%;height:auto}` **已经让显示
    ///      流式适配任何屏幕** —— 适配发生在渲染时，不在发送时。
    ///
    ///   **结论：分辨率归接收端，发送端不动它。** 本值只在图【异常巨大】时兜底
    ///   （远超任何电纸书屏 = 那已不是内容图，是意外），真实文章从不触发。
    static let maxEdge: CGFloat = 2400
    static let maxImages = 20
    /// 图片原始字节总量上限。**注意这是 base64 【之前】的字节数。**
    ///
    /// 【2026-07-19 审计 F-4 更正】原值 6MB，注释写「服务端上限 8MB，留余量」——
    /// 余量实测为 **0**：
    ///     6 MiB 原始 = 6,291,456 B → base64 = 8,388,608 B = 8 MiB = MAX_JSON_BODY_SIZE
    /// 即仅图片部分就恰好顶满服务端上限，正文文字、每张图的 `data:image/jpeg;base64,`
    /// 前缀、markdown 语法、JSON 信封与转义**全部溢出** → 413，整篇投递失败且无回退。
    /// 客户端按【原始字节】记预算、服务端按【编码后字节】设上限，两处口径不一致。
    ///
    /// 改 4MB：base64 后约 5.33MB，给正文与信封留约 2.6MB。
    static let maxTotalBytes = 4 * 1024 * 1024
    static let perImageTimeout: TimeInterval = 8

    /// JPEG 质量。
    ///
    /// 【为什么是 0.5 而非 0.75 —— 真机实测】首版带图投递的 12 张真图，q75 处理后
    /// **总共只省 1%**（1084KB→1074KB）：微信给的本就是压好的 JPEG，q75 再编码几乎
    /// 不动，于是"处理后变大就回退原图"那条**天天触发** —— 12 张图的灰度全白做了。
    /// **参数选错，让整个处理步骤退化成纯烧 CPU。**
    ///   q75 → 省 1%   |   q60 → 省 19%   |   **q50 → 省 37%**（全程原生分辨率不缩）
    ///
    /// 【为什么 q50 在这里安全】电纸书**无论多大**都只有 16 级灰度。q50 与 q75 的
    /// 差别经 16 级量化 + 抖动之后**不可见** —— 这不是"够用就行"的妥协，是那些比特
    /// **在目标设备上物理不存在**。
    ///
    /// 【为什么这不违反上面"分辨率归接收端"】**色深是设备类别的属性，分辨率是单机的
    /// 属性。** "电纸书是灰度的"对 P6、Tango、以及所有未来型号一律成立；"屏宽是多少"
    /// 则每台不同。前者可以在发送端断言，后者不能。
    static let jpegQuality: CGFloat = 0.5

    private static let mdImage = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\((https?://[^)\s]+)\)"#)

    /// 把 markdown 里的远程图换成 data: URI。**任何一张失败都只丢那一张，正文照常。**
    ///
    /// completion 在主线程回调。
    static func inline(markdown: String, completion: @escaping (String) -> Void) {
        let ns = markdown as NSString
        let matches = mdImage.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { completion(markdown); return }

        let targets = Array(matches.prefix(maxImages))   // 超量的下面原样丢弃
        var dataURIs = [Int: String]()
        let lock = NSLock()
        var totalBytes = 0
        let group = DispatchGroup()

        for (i, m) in targets.enumerated() {
            guard let url = URL(string: ns.substring(with: m.range(at: 2))) else { continue }
            group.enter()
            fetchAndEncode(url) { uri, bytes in
                lock.lock()
                // 总量封顶在【收到之后】判：并发取图，事前不知道谁多大。
                if let uri = uri, totalBytes + bytes <= maxTotalBytes {
                    totalBytes += bytes
                    dataURIs[i] = uri
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            var out = markdown
            // 【倒序替换】正序会让前面的替换把后面 match 的 range 全部偏移。
            for (i, m) in targets.enumerated().reversed() {
                let alt = ns.substring(with: m.range(at: 1))
                if let uri = dataURIs[i] {
                    out = (out as NSString).replacingCharacters(in: m.range, with: "![\(alt)](\(uri))")
                } else {
                    // 取不到/超量/坏图 → 整条丢掉。留着远程 URL 到服务端也会被丢，
                    // 不如在这里就省掉那几十字节。
                    out = (out as NSString).replacingCharacters(in: m.range, with: "")
                }
            }
            // 超过 maxImages 的那些 match 没进 targets，仍是远程 URL；服务端会丢弃。
            completion(out)
        }
    }

    private static func fetchAndEncode(_ url: URL,
                                       _ done: @escaping (String?, Int) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = perImageTimeout
        // 微信 CDN 实测无防盗链，UA 只为与抓 HTML 那条通道保持一致。
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let raw = data, !raw.isEmpty,
                  let cg = decode(raw) else {
                done(nil, 0); return                     // 拉不到/不是图 → 丢这一张
            }
            let (bytes, mime) = process(original: raw, cgImage: cg)
            done("data:\(mime);base64," + bytes.base64EncodedString(), bytes.count)
        }.resume()
    }

    /// 解码图像数据为 CGImage。失败返回 nil（调用方据此丢图）。
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 处理一张图。**核心规则：处理后比原图大，就用原图。**
    ///
    /// 灰度/再编码在大 PNG 上大赚（182KB→80KB），在已压好的 JPEG 和小 PNG 上却是
    /// 净亏（31KB→47KB、1.2KB→6.3KB，后者大 5 倍）。既然赚赔取决于原图，那就
    /// 【实际比一比】，别按规则猜。同 `strip_scripts` 只剥 script 不剥 style 的判据：
    /// **不做无收益的转换。**
    static func process(original: Data, cgImage: CGImage) -> (Data, String) {
        let origMime = sniffMime(original)
        // CGImage.width / .height 直接就是像素（与旧版 UIImage.size * scale 等价）。
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)

        // 只在【异常巨大】时缩，绝不放大。
        //
        // 「绝不放大」是实测教训：我第一版用了 `sips -Z 1440` 那种"缩放到框内"的
        // 语义，它会把小图【放大】—— 197×197 变成 1440×1440（7 倍），4 张图
        // 247KB 反而涨成 378KB。**"降采样"不带"绝不放大"的约束，就是在制造体积。**
        var work = cgImage
        if w > maxEdge || h > maxEdge {
            let s = min(maxEdge / w, maxEdge / h)
            let outW = Int(w * s), outH = Int(h * s)
            // 用 if let 而非 guard：这里的失败【不是】要退出整个 process，而是
            // "缩不了就别缩，拿原图继续走灰度" —— guard 的语义是退出作用域，与此相反。
            if let ctx = CGContext(data: nil, width: outW, height: outH,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                // 【顺序】必须先 draw 再 makeImage —— makeImage 取的是当前位图快照，
                // 画之前取就是一张空图。
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
                if let resized = ctx.makeImage() { work = resized }
            }
        }

        // 灰度（电纸书是灰度屏，彩色信息在设备上本就丢失）
        var candidate: Data? = nil
        if let gray = grayscale(work),
           let jpeg = jpegEncode(gray, quality: jpegQuality) {
            candidate = jpeg
        }
        if let c = candidate, c.count < original.count {
            return (c, "image/jpeg")          // 处理后更小 → 用它
        }
        // 处理后更大（或失败）→ 原图直传。这是实测得来的规则，不是保守。
        return (original, origMime)
    }

    /// 灰度处理。CIContext 未复用：CIContext 不保证线程安全，本函数会在 URLSession
    /// 并发回调中被调用，每次新建避免竞态。
    static func grayscale(_ cg: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIPhotoEffectMono") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let out = f.outputImage else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }

    /// 将 CGImage 编码为 JPEG Data。
    static func jpegEncode(_ cg: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        // 用 "public.jpeg" 字面量而非 kUTTypeJPEG：后者在 MobileCoreServices 且已
        // deprecated；UTType.jpeg.identifier 需要 iOS 14+/macOS 11+（本项目满足，
        // 但字面量更直接）。两者等价。
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, cg, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 按魔数认格式 —— 不信扩展名，也不信 Content-Type（微信 CDN 给的未必准）。
    static func sniffMime(_ d: Data) -> String {
        if d.count >= 3, d[0] == 0xFF, d[1] == 0xD8 { return "image/jpeg" }
        if d.count >= 8, d[0] == 0x89, d[1] == 0x50 { return "image/png" }
        if d.count >= 6, d[0] == 0x47, d[1] == 0x49 { return "image/gif" }
        if d.count >= 12, d[8] == 0x57, d[9] == 0x45 { return "image/webp" }
        return "image/jpeg"
    }
}
