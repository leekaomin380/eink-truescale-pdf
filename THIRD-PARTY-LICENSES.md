# 第三方组件与许可

本项目自身以 MIT 许可发布（见 [LICENSE](LICENSE)）。

为让 macOS 应用「装上即可用、无需先安装 Homebrew」，发布的 `.app` **内含**下列
第三方可执行文件与动态库。它们各自的许可与本项目的 MIT 许可**互不改变**：
应用通过启动独立进程调用它们，未在代码层链接，属 GPL 意义上的 mere aggregation。

分发这些二进制会触发相应义务，下面逐项说明如何履行。

---

## 组件清单

| 组件 | 版本 | 许可 | 在 `.app` 中的位置 |
|---|---|---|---|
| [pandoc](https://github.com/jgm/pandoc) | 3.10 | GPL-2.0-or-later | `Contents/Resources/bin/pandoc` |
| [typst](https://github.com/typst/typst) | 0.15.1 | Apache-2.0 | `Contents/Resources/bin/typst` |
| [GNU MP (libgmp)](https://gmplib.org/) | 6.x | LGPL-3.0-or-later **或** GPL-2.0-or-later | `Contents/Resources/lib/libgmp.10.dylib` |

许可全文随 `.app` 一同分发，位于 `Contents/Resources/licenses/`。

未打包、作为**可选**外部依赖的组件（仅 mobi/azw 转换需要）：

| 组件 | 许可 | 说明 |
|---|---|---|
| [Calibre](https://calibre-ebook.com/) 的 `ebook-convert` | GPL-3.0 | 是完整应用、数百 MB，不打包；缺失时仅 mobi/azw 不可用，其余格式不受影响 |

---

## 对二进制所做的改动

必须如实声明：**pandoc 的二进制被修改过**，但仅限于加载路径，程序逻辑未变。

1. **重定位动态库引用**（`install_name_tool -change`）
   pandoc 原本以绝对路径 `/opt/homebrew/opt/gmp/lib/libgmp.10.dylib` 引用 libgmp。
   在没有 Homebrew 的机器上该路径不存在，应用会在启动时 dyld 崩溃。
   故改写为 `@executable_path/../lib/libgmp.10.dylib`，指向 `.app` 内自带的副本。
   libgmp 自身的 install ID 同样被改写（`install_name_tool -id`）。

2. **重新 ad-hoc 签名**（`codesign -f -s -`）
   改动 Mach-O 会使原签名失效，未重签的二进制会被 macOS 直接终止。

上述改动**不涉及源代码**，二者均由 [`gui/build-app.sh`](gui/build-app.sh) 自动完成，
过程完全可复现、可审计。

---

## 如何获取对应源码（履行 GPL 义务）

pandoc 与 libgmp 均以未经源码修改的形式分发，其完整源码可从上游取得：

- **pandoc 3.10** — <https://github.com/jgm/pandoc/releases/tag/3.10>
- **GNU MP** — <https://gmplib.org/download/gmp/>（版本号见 `.app` 内
  `Contents/Resources/lib/libgmp.10.dylib` 或 `brew info gmp`）

本项目使用的二进制来自 Homebrew，其构建配方（同样公开、可复现）见：

- <https://github.com/Homebrew/homebrew-core/blob/master/Formula/p/pandoc.rb>
- <https://github.com/Homebrew/homebrew-core/blob/master/Formula/g/gmp.rb>

若上述链接失效，或你需要与所收到二进制**完全对应**的源码副本，
可通过 [README](README.md) 中的联系方式索取，我会提供。

---

## 架构限制（与许可无关，但同属分发须知）

打包进 `.app` 的引擎均为 **arm64（Apple Silicon）**。

因此发布的 `.app` **仅适用于 Apple Silicon Mac**（M1 及更新机型）。
Intel Mac 用户需自行从源码构建（`./gui/build-app.sh`，构建机需先
`brew install pandoc typst`，会自动打包该机器架构的二进制）。

判断自己的机型：菜单 →「关于本机」，芯片一栏若为 Apple M 系列即可使用。
