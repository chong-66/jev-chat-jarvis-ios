import SwiftUI

/// 试一试页：不切去微信，直接在 App 里跑完整管线，验证配置是否通。
struct PlaygroundView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var message = "这个需求你今天跟一下，明天早上给我"
    @State private var running = false
    @State private var stage = ""
    @State private var analysis: Analysis?
    @State private var context = ""
    @State private var generationTask: Task<Void, Never>?
    @State private var requestGate = JevRequestGate()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 70)
                        .font(.subheadline)
                        .disabled(running)
                    Button {
                        run()
                    } label: {
                        if running {
                            HStack { ProgressView().controlSize(.small); Text(stage.isEmpty ? "分析中…" : stage) }
                        } else {
                            Label("运行分析", systemImage: "play.fill")
                        }
                    }
                    .disabled(running || message.trimmingCharacters(in: .whitespaces).isEmpty)
                    if running {
                        Button("停止生成", role: .cancel) { cancel() }
                    }
                } header: {
                    Text("要回的消息")
                } footer: {
                    Text("这里验证主 App 的模型连接。聊天键盘还需要完全访问和共享配置，请到「开始」页确认键盘回写状态。")
                }

                Section("上下文（可选，仅供本页测试）") {
                    TextEditor(text: $context)
                        .frame(minHeight: 70)
                        .font(.subheadline)
                        .disabled(running)
                    Text("可按“我：… / 对方：…”补充最近对话，最多 6000 字。运行时会一起发给模型。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("清空上下文") { context = "" }.disabled(running)
                }

                if let a = analysis {
                    AnalysisResultView(analysis: a)
                }
            }
            .navigationTitle("试一试")
        }
        .onDisappear { cancel() }
    }

    private func cancel() {
        requestGate.cancel()
        generationTask?.cancel()
        generationTask = nil
        running = false
    }

    private func run() {
        cancel()
        guard context.count <= 6000 else {
            analysis = Analysis(message: message, fatalError: "上下文最多 6000 字，请缩短后重试")
            return
        }
        let id = requestGate.begin()
        running = true
        analysis = nil
        let pipeline = JevPipeline(cfg: store.config)
        let msg = message
        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        generationTask = Task { @MainActor in
            let result = await pipeline.analyze(message: msg, context: ctx.isEmpty ? nil : ctx) { s in
                Task { @MainActor in
                    guard requestGate.accepts(id) else { return }
                    switch s {
                    case .judging: stage = "判断中…"
                    case .drafting(let d, let t): stage = "生成中 \(d)/\(t)…"
                    case .ranking: stage = "排序中…"
                    case .done: stage = "完成"
                    }
                }
            }
            guard requestGate.accepts(id), !Task.isCancelled else { return }
            requestGate.finish(id)
            analysis = result
            running = false
            generationTask = nil
        }
    }
}

/// 结果卡：判断头 + 候选列表（点复制）。
struct AnalysisResultView: View {
    let analysis: Analysis

    var body: some View {
        Section {
            if let jr = analysis.judge {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(jr.intent)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                        Text(String(format: "风险 %.0f/9", jr.risk))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(riskColor(jr.risk))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(riskColor(jr.risk).opacity(0.12), in: Capsule())
                        Spacer()
                        Text(String(format: "%.0f%% · %.1fs", jr.confidence * 100, analysis.elapsed))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(jr.riskLevelText).font(.caption).foregroundStyle(riskColor(jr.risk))
                    if !jr.actions.isEmpty {
                        Text("建议：" + jr.actions.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(analysis.candidates) { c in
                HStack(alignment: .top) {
                    Text(c.tone)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    Text(c.text).font(.subheadline)
                    Spacer()
                    if let p = c.prob {
                        Text(String(format: "%.0f%%", p * 100))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = c.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }

            ForEach(analysis.notices, id: \.self) { n in
                Text("· " + n).font(.caption).foregroundStyle(.orange)
            }

            if let fatal = analysis.fatalError {
                Text(fatal).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("结果")
        }
    }

    private func riskColor(_ r: Double) -> Color {
        switch r {
        case ..<3: return .green
        case ..<6: return .yellow
        case ..<8: return .orange
        default: return .red
        }
    }
}
