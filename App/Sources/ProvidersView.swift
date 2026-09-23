import SwiftUI

/// 模型页：生成层（必需）+ 判断层（可选）。改完即存，键盘下次分析生效。
struct ProvidersView: View {
    @EnvironmentObject private var store: ConfigStore

    var body: some View {
        NavigationStack {
            Form {
                judgeSection
                generationSection
            }
            .navigationTitle("模型")
        }
    }

    // MARK: 生成层

    private var generationSection: some View {
        Section {
            Picker("预设", selection: $preset) {
                ForEach(ProviderPreset.all) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .onChange(of: preset) { id in
                applyPreset(id)
            }

            Picker("API 形状", selection: $store.config.genKind) {
                ForEach(APIKind.allCases) { k in
                    Text(k.label).tag(k)
                }
            }

            TextField("服务地址", text: $store.config.genBase)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.footnote)

            KeyField(title: "API Key", text: $store.config.genKey)

            TextField("模型", text: $store.config.genModel)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.footnote)

            TextField("额外字段 JSON（可选）", text: $store.config.genExtraJSON, axis: .vertical)
                .font(.footnote.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(1...3)

            TestConnectionButton(kind: .generation)

            Text(genStatusLine)
                .font(.caption2).foregroundStyle(.secondary)
        } header: {
            Text("生成层（候选回复，必配）")
        } footer: {
            Text("不填 Key 时自动走内置中转（\(JevBuiltin.baseURL) · \(JevBuiltin.model)），填了自己的 Key 就以你的为准。别用思考型模型（思考会占满额度导致 0 条候选）。地址带不带 /v1 都能拼对；端点需要额外字段关思考时填上面那行，默认已带 enable_thinking:false。")
        }
    }

    /// 显示实际生效的那一组，而不是输入框里的值——没填 key 时用的是内置中转。
    private var genStatusLine: String {
        let g = store.config.generation
        let key = g.isBuiltin ? "内置中转（免填）" : JevStore.masked(g.key)
        return "当前：\(g.kind.rawValue) · \(g.model) · Key \(key)"
    }

    @State private var preset: String = "builtin"

    private func applyPreset(_ id: String) {
        guard let p = ProviderPreset.all.first(where: { $0.id == id }), p.id != "custom" else { return }
        store.config.genKind = p.kind
        store.config.genBase = p.base
        store.config.genModel = p.model
    }

    // MARK: 判断层

    @State private var judgePreset: String = "typesafe"

    private var judgeSection: some View {
        Section {
            Picker("预设", selection: $judgePreset) {
                ForEach(JudgePreset.all) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .onChange(of: judgePreset) { id in
                if let p = JudgePreset.all.first(where: { $0.id == id }), p.id != "custom" {
                    store.config.judgeBase = p.base
                    store.config.judgeModel = p.model
                }
            }

            TextField("服务地址", text: $store.config.judgeBase)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.footnote)
            KeyField(title: "API Key", text: $store.config.judgeKey)
            TextField("模型", text: $store.config.judgeModel)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.footnote)

            TestConnectionButton(kind: .judge)

            Text("当前：\(store.config.judgeModel) · Key \(JevStore.masked(store.config.judgeKey))")
                .font(.caption2).foregroundStyle(.secondary)
        } header: {
            Text("判断层（Jev · 意图 + 风险 + 排序）")
        } footer: {
            Text("核心判断引擎：一次调用出 8 类意图概率和 0–9 风险分布，并给候选排序。没填 key 时键盘退化为「盲起草」（只出候选）。网关地址填到动作段或带 /v1 都能拼对；key 与生成层可以不是同一家。")
        }
    }
}

// MARK: - 密钥输入框（默认明文方便粘贴核对，眼睛切换掩码）

private struct KeyField: View {
    let title: String
    @Binding var text: String
    @State private var hidden = false

    var body: some View {
        HStack(spacing: 8) {
            if hidden {
                SecureField(title, text: $text)
                    .font(.footnote)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                TextField(title, text: $text)
                    .font(.footnote)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Button {
                hidden.toggle()
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        // 每次进到这个页面都回到明文：掩码只是"有人在旁边"时的临时状态，
        // 不该留着——否则下次进来（哪怕 App 被系统恢复过）密钥还是被遮着的，
        // 既没法核对也没法粘贴。判断层和生成层两个框共用这个组件，行为一致。
        .onAppear { hidden = false }
    }
}

// MARK: - 测试连接

private struct TestConnectionButton: View {
    enum Kind { case generation, judge }
    let kind: Kind

    @EnvironmentObject private var store: ConfigStore
    @State private var running = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                test()
            } label: {
                if running {
                    HStack { ProgressView().controlSize(.small); Text("测试中…") }
                } else {
                    Label("测试连接", systemImage: "bolt.horizontal")
                }
            }
            .disabled(running)

            if let result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✅") ? Color.green : Color.red)
            }
        }
    }

    private func test() {
        running = true
        result = nil
        let cfg = store.config
        Task {
            do {
                switch kind {
                case .generation:
                    let draft = JevDraft(cfg: cfg)
                    guard draft.isConfigured else { throw JevError.missingKey("生成层 API Key") }
                    let text = try await draft.call(prompt: "回复两个字：收到")
                    result = "✅ 成功，模型回了：\(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))"
                case .judge:
                    let judge = JevJudge(cfg: cfg)
                    guard judge.isConfigured else { throw JevError.missingKey("判断层 API Key") }
                    let jr = try await judge.judge(message: "这个需求你今天跟一下", context: nil)
                    result = String(format: "✅ 成功：意图「%@」（%.0f%%），风险 %.1f/9", jr.intent, jr.confidence * 100, jr.risk)
                }
            } catch {
                result = "❌ \(error.localizedDescription)"
            }
            running = false
        }
    }
}
