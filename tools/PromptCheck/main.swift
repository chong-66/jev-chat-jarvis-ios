import Foundation

// 口径回归：在 Mac 上直接跑（不依赖 iPhone/键盘环境），
// 用法：swift tools/PromptCheck/main.swift ../Shared/*.swift（见 tools/PromptCheck/run.sh）
// 与 macOS 版对齐的判定点全部来自 src/generate.py #42 拼接规则与 _parse 清洗。

var pass = 0, fail = 0

func check(_ name: String, _ got: String, _ want: String) {
    if got == want { pass += 1; print("✅ \(name): \(got)") }
    else { fail += 1; print("❌ \(name)\n   got  \(got)\n   want \(want)") }
}

// MARK: Jev 判断层 URL 拼接（三种填法等价可用）

check("jev 主机", JevJudge.requestURL("https://api.typesafe.ai"), "https://api.typesafe.ai/v1/systemone")
check("jev 带版本段", JevJudge.requestURL("https://api.typesafe.ai/v1"), "https://api.typesafe.ai/v1/systemone")
check("jev 完整动作段 verbatim", JevJudge.requestURL("https://ai-gateway.vercel.sh/v1/evaluate"), "https://ai-gateway.vercel.sh/v1/evaluate")
check("jev openrouter decisions", JevJudge.requestURL("https://openrouter.ai/api/alpha/decisions"), "https://openrouter.ai/api/alpha/decisions")
check("jev 末尾斜杠", JevJudge.requestURL("https://api.typesafe.ai/"), "https://api.typesafe.ai/v1/systemone")
check("jev v2 版本段", JevJudge.requestURL("https://gw.example.com/v2"), "https://gw.example.com/v2/systemone")

// MARK: 生成层 URL 拼接

check("openai 主机", JevDraft.chatURL("https://api.deepseek.com", kind: .openai), "https://api.deepseek.com/chat/completions")
check("openai v1", JevDraft.chatURL("https://api.deepseek.com/v1", kind: .openai), "https://api.deepseek.com/v1/chat/completions")
check("openai 智谱 v4", JevDraft.chatURL("https://open.bigmodel.cn/api/paas/v4", kind: .openai), "https://open.bigmodel.cn/api/paas/v4/chat/completions")
check("openai 已带动作段", JevDraft.chatURL("https://x.com/v1/chat/completions", kind: .openai), "https://x.com/v1/chat/completions")
check("anthropic 主机", JevDraft.chatURL("https://api.anthropic.com", kind: .anthropic), "https://api.anthropic.com/v1/messages")
check("anthropic 智谱中转", JevDraft.chatURL("https://open.bigmodel.cn/api/anthropic", kind: .anthropic), "https://open.bigmodel.cn/api/anthropic/v1/messages")

// MARK: 候选清洗（编号 → 引号 → 风格前缀 → 引号）

check("清洗·编号", CandidateParser.parseLine("1. 收到，明天上午给你")!, "收到，明天上午给你")
check("清洗·顿号编号", CandidateParser.parseLine("2、在忙，你说")!, "在忙，你说")
check("清洗·包裹引号", CandidateParser.parseLine("「好的没问题」")!, "好的没问题")
check("清洗·风格前缀", CandidateParser.parseLine("稳妥版：三点前给你")!, "三点前给你")
check("清洗·短风格词", CandidateParser.parseLine("简：我先确认下")!, "我先确认下")
check("清洗·编号+前缀", CandidateParser.parseLine("1. **轻松型**：这就去整")!, "这就去整")
check("清洗·正常句不动", CandidateParser.parseLine("简单说：我先确认一下流程")!, "简单说：我先确认一下流程")

let multi = CandidateParser.parse("""
1. 收到，明早九点前给你
2. 收到收到，我今晚就盯完
已读乱回：嗯嗯，在弄
""")
check("解析·两行候选", "\(multi.count)", "2")
check("解析·去重保留", "\(multi.first!)", "收到，明早九点前给你")

// MARK: 起草 prompt 结构（关键占位符必须全部替换干净）

let p = buildDraftPrompt(message: "这个需求你今天跟一下", intent: "催进度", context: nil,
                         tone: "稳如老狗", instruction: "十年老工程师那种稳", n: 2)
check("prompt·意图行", p.contains("判断出的意图：催进度") ? "ok" : "missing", "ok")
check("prompt·话术行", p.contains("「稳如老狗」十年老工程师那种稳") ? "ok" : "missing", "ok")
check("prompt·无残留占位符", p.contains("{") ? "has-placeholder" : "clean", "clean")
check("prompt·条数一致", p.components(separatedBy: "请写 2 条").count == 2 ? "ok" : "bad", "ok")

let p2 = buildDraftPrompt(message: "在吗", intent: nil, context: "王总: 昨天的方案看完了吗",
                          tone: "已读乱回", instruction: "敷衍但不失礼", n: 2)
check("prompt·上下文行", p2.contains("最近的对话：\n王总: 昨天的方案看完了吗") ? "ok" : "missing", "ok")
check("prompt·无意图时省略", p2.contains("判断出的意图") ? "bad" : "ok", "ok")

// MARK: 风险标签映射

check("风险·0 分", riskLabel(for: 0), RISK_LEVELS[0])
check("风险·四舍五入", riskLabel(for: 4.6), RISK_LEVELS[5])
check("风险·封顶", riskLabel(for: 8.9), RISK_LEVELS[9])

// MARK: 重签后的共享组与配置迁移

let hostID = "com.jevchat.jarvis.ios.TESTTEAM01"
let signedGroup = "group." + hostID
let hostGroups = JevSharedGroup.candidates(bundleID: hostID, isKeyboard: false)
let keyboardGroups = JevSharedGroup.candidates(bundleID: hostID + ".keyboard", isKeyboard: true)
check("共享·重签 App 与键盘组名一致", hostGroups.joined(separator: ","), keyboardGroups.joined(separator: ","))
check("共享·优先重签组", hostGroups.first ?? "nil", signedGroup)
check("共享·原版不重复候选", "\(JevSharedGroup.candidates(bundleID: "com.jevchat.jarvis.ios", isKeyboard: false).count)", "1")
check("共享·无 bundle ID", JevSharedGroup.candidates(bundleID: nil, isKeyboard: false).first!, JevSharedGroup.originalID)
check("共享·拒绝猜测未知扩展后缀", JevSharedGroup.candidates(bundleID: hostID + ".unknown", isKeyboard: true).joined(), JevSharedGroup.originalID)
check("共享·两组都有权限时选择重签组", JevSharedGroup.resolve(hostGroups) { _ in true } ?? "nil", signedGroup)
check("共享·原组仍可用时回退", JevSharedGroup.resolve(hostGroups) { $0 == JevSharedGroup.originalID } ?? "nil", JevSharedGroup.originalID)
check("共享·无权限不能假报可用", JevSharedGroup.resolve(hostGroups) { _ in false } ?? "nil", "nil")

// Isolated stores model the previous private suite, host backup, and new group.
// Never use real credentials or the user's preference domains in these checks.
let testPrefix = "jev.tests." + UUID().uuidString
let domainNames = ["shared", "local", "legacy"].map { testPrefix + "." + $0 }
let testStores = domainNames.map { UserDefaults(suiteName: $0)! }
let sharedStore = testStores[0], localStore = testStores[1], legacyStore = testStores[2]
func resetStores() {
    for (index, name) in domainNames.enumerated() { testStores[index].removePersistentDomain(forName: name) }
}
var legacyConfig = JevConfig()
legacyConfig.genKey = "test-only-placeholder"
legacyConfig.genModel = "test-model"
legacyConfig.slots = ["测试话术"]
let encodedLegacy = try! JSONEncoder().encode(legacyConfig)
legacyStore.set(encodedLegacy, forKey: "jev.config.v1")
let migrated = JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: false)
check("迁移·保留旧配置", "\(migrated == legacyConfig)", "true")
check("迁移·写入共享区", "\(sharedStore.data(forKey: "jev.config.v1") != nil)", "true")
check("迁移·键盘读到迁移配置", "\(JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: nil, isKeyboard: true) == legacyConfig)", "true")
var currentConfig = legacyConfig
currentConfig.genModel = "new-model"
sharedStore.set(try! JSONEncoder().encode(currentConfig), forKey: "jev.config.v1")
check("迁移·旧备份不能覆盖现有共享配置", JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: false).genModel, "new-model")
resetStores()
legacyStore.set(encodedLegacy, forKey: "jev.config.v1")
localStore.set(encodedLegacy, forKey: "jev.config.v1")
_ = JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: true)
check("迁移·键盘不能向空共享区写入本地数据", "\(sharedStore.data(forKey: "jev.config.v1") == nil)", "true")
check("迁移·共享不可用时主 App 保留配置", "\(JevStore.loadConfig(shared: nil, local: localStore, legacy: legacyStore, isKeyboard: false) == legacyConfig)", "true")
check("迁移·键盘不可误用私有配置", "\(JevStore.loadConfig(shared: nil, local: localStore, legacy: legacyStore, isKeyboard: true) == JevConfig())", "true")
resetStores()
sharedStore.set(Data("not-json".utf8), forKey: "jev.config.v1")
legacyStore.set(encodedLegacy, forKey: "jev.config.v1")
check("迁移·损坏共享配置可从主 App 恢复", "\(JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: false) == legacyConfig)", "true")
resetStores()
let oldStatusData = Data("{\"lastSeen\":0,\"hasFullAccess\":true}".utf8)
let oldStatus = try! JSONDecoder().decode(KeyboardStatus.self, from: oldStatusData)
check("状态·旧版回写不能冒充已读配置", "\(oldStatus.generationConfigured == nil)", "true")

// MARK: 重签后的共享组与配置迁移

let hostID = "com.jevchat.jarvis.ios.TESTTEAM01"
let signedGroup = "group." + hostID
let hostGroups = JevSharedGroup.candidates(bundleID: hostID, isKeyboard: false)
let keyboardGroups = JevSharedGroup.candidates(bundleID: hostID + ".keyboard", isKeyboard: true)
check("共享·重签 App 与键盘组名一致", hostGroups.joined(separator: ","), keyboardGroups.joined(separator: ","))
check("共享·优先重签组", hostGroups.first ?? "nil", signedGroup)
check("共享·原版不重复候选", "\(JevSharedGroup.candidates(bundleID: "com.jevchat.jarvis.ios", isKeyboard: false).count)", "1")
check("共享·无 bundle ID", JevSharedGroup.candidates(bundleID: nil, isKeyboard: false).first!, JevSharedGroup.originalID)
check("共享·拒绝猜测未知扩展后缀", JevSharedGroup.candidates(bundleID: hostID + ".unknown", isKeyboard: true).joined(), JevSharedGroup.originalID)
check("共享·两组都有权限时选择重签组", JevSharedGroup.resolve(hostGroups) { _ in true } ?? "nil", signedGroup)
check("共享·原组仍可用时回退", JevSharedGroup.resolve(hostGroups) { $0 == JevSharedGroup.originalID } ?? "nil", JevSharedGroup.originalID)
check("共享·无权限不能假报可用", JevSharedGroup.resolve(hostGroups) { _ in false } ?? "nil", "nil")

// Isolated stores model the previous private suite, host backup, and new group.
// Never use real credentials or the user's preference domains in these checks.
let testPrefix = "jev.tests." + UUID().uuidString
let domainNames = ["shared", "local", "legacy"].map { testPrefix + "." + $0 }
let testStores = domainNames.map { UserDefaults(suiteName: $0)! }
let sharedStore = testStores[0], localStore = testStores[1], legacyStore = testStores[2]
func resetStores() {
    for (index, name) in domainNames.enumerated() { testStores[index].removePersistentDomain(forName: name) }
}
var legacyConfig = JevConfig()
legacyConfig.genKey = "test-only-placeholder"
legacyConfig.genModel = "test-model"
legacyConfig.slots = ["测试话术"]
let encodedLegacy = try! JSONEncoder().encode(legacyConfig)
legacyStore.set(encodedLegacy, forKey: "jev.config.v1")
let migrated = JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: false)
check("迁移·保留旧配置", "\(migrated == legacyConfig)", "true")
check("迁移·写入共享区", "\(sharedStore.data(forKey: "jev.config.v1") != nil)", "true")
check("迁移·键盘读到迁移配置", "\(JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: nil, isKeyboard: true) == legacyConfig)", "true")
var currentConfig = legacyConfig
currentConfig.genModel = "new-model"
sharedStore.set(try! JSONEncoder().encode(currentConfig), forKey: "jev.config.v1")
check("迁移·旧备份不能覆盖现有共享配置", JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: false).genModel, "new-model")
resetStores()
legacyStore.set(encodedLegacy, forKey: "jev.config.v1")
localStore.set(encodedLegacy, forKey: "jev.config.v1")
_ = JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: true)
check("迁移·键盘不能向空共享区写入本地数据", "\(sharedStore.data(forKey: "jev.config.v1") == nil)", "true")
check("迁移·共享不可用时主 App 保留配置", "\(JevStore.loadConfig(shared: nil, local: localStore, legacy: legacyStore, isKeyboard: false) == legacyConfig)", "true")
check("迁移·键盘不可误用私有配置", "\(JevStore.loadConfig(shared: nil, local: localStore, legacy: legacyStore, isKeyboard: true) == JevConfig())", "true")
resetStores()
sharedStore.set(Data("not-json".utf8), forKey: "jev.config.v1")
legacyStore.set(encodedLegacy, forKey: "jev.config.v1")
check("迁移·损坏共享配置可从主 App 恢复", "\(JevStore.loadConfig(shared: sharedStore, local: localStore, legacy: legacyStore, isKeyboard: false) == legacyConfig)", "true")
resetStores()
let oldStatusData = Data("{\"lastSeen\":0,\"hasFullAccess\":true}".utf8)
let oldStatus = try! JSONDecoder().decode(KeyboardStatus.self, from: oldStatusData)
check("状态·旧版回写不能冒充已读配置", "\(oldStatus.generationConfigured == nil)", "true")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
