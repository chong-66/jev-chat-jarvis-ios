import SwiftUI

/// 配置的唯一可写入口：App 侧改完立刻落 App Group，键盘下次分析就能读到。
@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: JevConfig {
        didSet { JevStore.saveConfig(config) }
    }

    init() {
        config = JevStore.loadConfig()
    }

    var toneCatalog: [String: String] { allTones(custom: config.customTones) }
}

@main
struct JevJarvisApp: App {
    @StateObject private var store = ConfigStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                SetupView()
                    .tabItem { Label("开始", systemImage: "keyboard") }
                ProvidersView()
                    .tabItem { Label("模型", systemImage: "brain.head.profile") }
                TonesView()
                    .tabItem { Label("话术", systemImage: "theatermasks") }
                PlaygroundView()
                    .tabItem { Label("试一试", systemImage: "flask") }
            }
            .environmentObject(store)
        }
    }
}
