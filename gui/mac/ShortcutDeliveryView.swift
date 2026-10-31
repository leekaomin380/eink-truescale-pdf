import SwiftUI

struct ShortcutDeliveryMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("快捷投递设置…") { openWindow(id: "shortcut-delivery") }
    }
}

/// 菜单「快捷投递设置…」打开的独立窗口：与主窗口快捷投递页左栏相同的设置。
struct ShortcutDeliveryView: View {
    var body: some View {
        ScrollView { QuickSendSettings() }
            .frame(width: 480, height: 640)
    }
}
