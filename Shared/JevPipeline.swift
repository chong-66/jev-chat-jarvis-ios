import Foundation

// MARK: - 端到端管线：判断 → 起草（每话术并发）→ 排序
//
// 阶段间是「带截止时间的串行」：判断通常 ~1 秒，等它出来再把意图喂给起草，
// 候选质量明显更好；判断超时或没配 key 时直接盲起草（Windows 版同款回退）。
// 排序失败按「每个话术的第 1 条（稳妥款）在前」的默认顺序展示。

struct Candidate: Identifiable, Equatable {
    var id: String { text }
    var text: String
    var tone: String
    /// Jev 排序概率；没排序时为 nil
    var prob: Double?
}

struct Analysis: Equatable {
    var message: String
    var judge: JudgeResult?
    var candidates: [Candidate] = []
    /// 非致命错误（某话术失败、排序失败），界面黄条展示
    var notices: [String] = []
    /// 致命错误（生成层全挂），界面红条展示
    var fatalError: String?
    var elapsed: Double = 0
}

enum PipelineStage: Equatable {
    case judging
    case drafting(done: Int, total: Int)
    case ranking
    case done
}

final class JevPipeline {
    private let cfg: JevConfig
    private let judge: JevJudge
    private let draft: JevDraft

    init(cfg: JevConfig) {
        self.cfg = cfg
        self.judge = JevJudge(cfg: cfg)
        self.draft = JevDraft(cfg: cfg)
    }

    var generationConfigured: Bool { draft.isConfigured }

    /// 完整分析。永不 throw：致命问题进 fatalError，其余进 notices。
    func analyze(message: String, context: String?,
                 onStage: ((PipelineStage) -> Void)? = nil) async -> Analysis {
        let start = Date()
        var out = Analysis(message: message)

        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else {
            out.fatalError = "消息内容为空：请先在聊天里长按消息点「复制」，或把要回的话输进输入框"
            return out
        }
        guard draft.isConfigured else {
            out.fatalError = "还没配置生成层：打开 Jev Jarvis App →「模型」页填 API Key"
            return out
        }

        // 1) 判断（可选，带截止时间）
        var judgeResult: JudgeResult?
        if judge.isConfigured {
            onStage?(.judging)
            judgeResult = try? await withTimeout(seconds: 9) {
                try await self.judge.judge(message: msg, context: context)
            }
            if judgeResult == nil {
                out.notices.append("判断层没响应，已盲起草（不影响出候选）")
            }
        }
        out.judge = judgeResult

        // 2) 起草：一个话术一次请求，并发
        let tones = allTones(custom: cfg.customTones)
        let active = cfg.activeSlots.compactMap { name -> (String, String)? in
            guard let instruction = tones[name] else { return nil }
            return (name, instruction)
        }
        guard !active.isEmpty else {
            out.fatalError = "所有话术槽都是「不用」：打开 App →「话术」页至少启用一个"
            out.elapsed = Date().timeIntervalSince(start)
            return out
        }

        onStage?(.drafting(done: 0, total: active.count))
        var drafted: [Candidate] = []
        await withTaskGroup(of: (String, [String], String?).self) { group in
            for (name, instruction) in active {
                group.addTask {
                    do {
                        let texts = try await self.draft.draft(
                            message: msg, intent: judgeResult?.intent, context: context,
                            tone: name, instruction: instruction)
                        return (name, texts, nil)
                    } catch {
                        return (name, [], error.localizedDescription)
                    }
                }
            }
            var done = 0
            for await (name, texts, err) in group {
                done += 1
                onStage?(.drafting(done: done, total: active.count))
                if let err {
                    out.notices.append("「\(name)」失败：\(err)")
                }
                for t in texts { drafted.append(Candidate(text: t, tone: name, prob: nil)) }
            }
        }

        guard !drafted.isEmpty else {
            out.fatalError = out.notices.first ?? "候选生成失败：请到 App「模型」页点「测试连接」检查配置"
            out.elapsed = Date().timeIntervalSince(start)
            return out
        }

        // 3) 排序（可选）。失败按默认顺序：同话术的稳妥款在前。
        let ordered = active.map(\.0).flatMap { name in drafted.filter { $0.tone == name } }
        if judge.isConfigured, let jr = judgeResult {
            onStage?(.ranking)
            if let ranked = try? await withTimeout(seconds: 10, {
                try await self.judge.rank(message: msg, intent: jr.intent,
                                          candidates: ordered.map(\.text))
            }) {
                let toneBy = Dictionary(uniqueKeysWithValues: ordered.map { ($0.text, $0.tone) })
                out.candidates = ranked.compactMap { r in
                    guard let tone = toneBy[r.text] else { return nil }
                    return Candidate(text: r.text, tone: tone, prob: r.prob)
                }
            } else {
                out.notices.append("排序失败，按默认顺序展示")
                out.candidates = ordered
            }
        } else {
            out.candidates = ordered
        }

        out.elapsed = Date().timeIntervalSince(start)
        onStage?(.done)
        return out
    }

    // MARK: 超时包装（阶段级截止时间，比预算更硬：到点放弃该阶段而不是拖慢整体）

    private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw JevError.timeout("", seconds)
            }
            guard let first = try await group.next() else {
                throw JevError.cancelled
            }
            group.cancelAll()
            return first
        }
    }
}
