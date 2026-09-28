import UIKit

/// Jev 键盘：一个「回复面板」键盘，不是打字键盘。
///
/// 交互闭环（不跳出聊天 App）：
///   ① 在聊天里长按对方消息 → 复制
///   ② 键盘上点「分析剪贴板」→ 意图/风险 + 每话术 2 条候选
///   ③ 点候选 → 直接 insertText 进当前输入框（发送永远由用户手动完成）
///
/// 联网、读剪贴板、读共享配置都要求用户在系统设置里给「允许完全访问」——
/// 这是 iOS 键盘扩展的唯一开关，没有别的权限可申请。
final class KeyboardViewController: UIInputViewController {

    private enum Mode { case gate, idle, tones, context, refine, loading, result, error }

    private var mode: Mode = .idle
    private var lastSource: Source = .clipboard
    private var lastMessage: String = ""
    private var analysis: Analysis?
    private var errorText: String = ""
    private var stageLabel = UILabel()
    private var generationTask: Task<Void, Never>?
    private var requestGate = JevRequestGate()
    private var replyContext = JevReplyContext()
    private var contextDraftStore = JevContextDraftStore()
    private var contextSpeaker = JevReplyContext.Speaker.other
    private var contextError = ""
    private var lastContext: String?
    private var refinementIndex: Int?
    private var documentID: UUID?
    private var toneCategory: JevToneCategory = .partner
    private var tonePage = 0
    private static let tonesPerPage = 6
    private var keyboardVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知版本"
    }


    private enum Source { case clipboard, inputField }

    // MARK: 布局骨架

    private let topBar = UIView()
    private var statusLabel = UILabel()
    private let contentStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint!
    /// 当前状态里参与「按内容定高」的块，顺序即纵向顺序。
    /// 候选区放的是内部列表（list）而不是滚动视图（scroll）——滚动视图没有固有高度，
    /// 量它会得到 0，面板就会被算矮、候选被压没。
    private var fitBlocks: [UIView] = []
    private var lastFit: (mode: Mode, width: CGFloat)?
    /// 反馈要落在当前页面的那行小字上（结果页是脚注，初始页是顶部提示行）
    private weak var flashTarget: UILabel?
    /// 系统容器比我们视图高出的那一截（露出来就是顶部那条「色块」）；每次出现只量一次
    private var containerGap: CGFloat = 0
    private var didMeasureContainerGap = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // 面板底色交给系统，不要自己设：这个视图本身就是 UIInputView（.keyboard 样式），
        // 系统会给它画与键盘容器同一套底材。之前用自定义的 KB.bg 盖掉了它，于是我们面板
        // 和键盘顶部露出的那层底衬颜色对不上，看着就像多了一条"灰带"。
        // 不设背景色后两边同源同色，深色模式也跟着系统走。
        view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        restoreContextDraft()
        buildTopBar()
        buildContentStack()
        mode = hasFullAccess ? .idle : .gate
#if DEBUG
        // 自检探针：任何落到面板上的点按都记一笔，并报告命中的视图类型。
        // 用来区分「触摸压根没进来」和「进来了但没送到候选行」。
        let probe = UITapGestureRecognizer(target: self, action: #selector(diagProbe(_:)))
        probe.cancelsTouchesInView = false
        view.addGestureRecognizer(probe)
#endif
        render()
    }

#if DEBUG
    @objc private func diagProbe(_ g: UITapGestureRecognizer) {
        let p = g.location(in: view)
        let hit = view.hitTest(p, with: nil)
        JevStore.diag(String(format: "面板点按 (%.0f,%.0f) 命中=%@", p.x, p.y,
                             String(describing: type(of: hit ?? UIView())))
            + " 状态=\(mode)")
    }
#endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreContextDraft()
        synchronizeDocument()
        // 回写状态：主 App「开始」页据此显示键盘是否已启用、是否给了完全访问
        reportConfigurationStatus()
        if !hasFullAccess { setMode(.gate) }
        else if mode == .gate || mode == .idle { setMode(.idle) }
        else if mode == .context { render() }
        prewarm()
        // 刚出现时 frame 还没定，等键盘铺开后再量容器间隙
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.coverContainerGap()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelRequest()
        if mode == .loading { setMode(analysis?.candidates.isEmpty == false ? .result : .idle) }
        else if mode == .result { render() }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        synchronizeDocument()
    }

    /// Hosts may reuse the same input view for multiple chats, so the context
    /// panel also explicitly asks users to clear context when switching people.
    private func synchronizeDocument() {
        synchronizeDocument(with: textDocumentProxy.documentIdentifier)
    }

    private func synchronizeDocument(with current: UUID) {
        guard current != documentID else { return }
        cancelRequest()
        documentID = current
        // Input identity changes cancel results, but must not erase a draft
        // being collected by copying several messages in the host app.
        lastContext = nil
        lastMessage = ""
        analysis = nil
        refinementIndex = nil
        contextError = ""
        setMode(hasFullAccess ? .idle : .gate)
    }

    private func accepts(_ id: UUID, document: UUID) -> Bool {
        requestGate.accepts(id) && hasFullAccess && textDocumentProxy.documentIdentifier == document
    }

    private func cancelRequest() {
        requestGate.cancel()
        generationTask?.cancel()
        generationTask = nil
        analysis?.rankingPending = false
    }

    @objc private func stopGeneration() {
        cancelRequest()
        setMode(analysis?.candidates.isEmpty == false ? .result : .idle)
        flashFooter("已停止，已生成的候选仍可使用", color: KB.secondaryText)
    }

    private func reportConfigurationStatus() {
        JevStore.saveKeyboardStatus(KeyboardStatus(
            lastSeen: Date(), hasFullAccess: hasFullAccess,
            generationConfigured: !JevStore.loadConfig().generation.key.isEmpty,
            keyboardVersion: keyboardVersion, presetCount: BUILTIN_TONES.count))
    }

    /// 预热生成层连接。实测同一条起草请求，第二次能从 ~1.9 秒降到 ~0.5 秒——
    /// 连接和中转上游都要热身。键盘一出现就用一个不消耗额度的 `GET /models` 把连接建起来，
    /// 结果直接丢掉（失败也无所谓，真分析时该走的路径照走）。
    private func prewarm() {
        guard hasFullAccess else { return }
        let g = JevStore.loadConfig().generation
        guard !g.key.isEmpty, !g.base.isEmpty else { return }
        let base = g.base.hasSuffix("/") ? String(g.base.dropLast()) : g.base
        guard let url = URL(string: base + "/models") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(g.key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        view.layer.borderColor = KB.cardBorder.cgColor
        // 重建各状态视图以刷新动态色
        if mode == .idle || mode == .gate { render() }
    }

    // MARK: 顶栏：品牌 + 状态 + 系统键盘切换 + 删除

    private func buildTopBar() {
        let dot = UIView()
        dot.backgroundColor = hasFullAccess ? KB.riskColor(0) : .systemRed
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        statusLabel = KB.label("Jev \(keyboardVersion) · " + (hasFullAccess ? "已连接" : "需要完全访问"),
                               font: .systemFont(ofSize: 12, weight: .medium), color: KB.secondaryText)

        statusLabel.accessibilityIdentifier = "keyboard.version"
        let title = UIStackView(arrangedSubviews: [dot, statusLabel])
        title.axis = .horizontal
        title.spacing = 6
        title.alignment = .center

        let globe = KB.button("", icon: "globe")
        globe.addTarget(self, action: #selector(switchKeyboard), for: .touchUpInside)
        NSLayoutConstraint.activate([
            globe.widthAnchor.constraint(equalToConstant: 44),
            globe.heightAnchor.constraint(equalToConstant: 36),
        ])

        let backspace = KB.button("", icon: "delete.left")
        backspace.addTarget(self, action: #selector(deleteBackwardTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            backspace.widthAnchor.constraint(equalToConstant: 44),
            backspace.heightAnchor.constraint(equalToConstant: 36),
        ])

        topBar.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        let hstack = UIStackView(arrangedSubviews: [UIView(), globe, backspace])
        hstack.axis = .horizontal
        hstack.spacing = 8
        topBar.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            topBar.heightAnchor.constraint(equalToConstant: 36),
            title.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: hstack.leadingAnchor, constant: -6),
            hstack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            hstack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
        ])
    }

    private func buildContentStack() {
        contentStack.axis = .vertical
        contentStack.spacing = 6
        view.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heightConstraint,
        ])
    }

    /// 面板高度按内容实测定，而不是把 320 写死。
    ///
    /// 写死一个高度 + UIStackView 默认的 .fill：多余的垂直空间会被平分下去，卡片被拉伸出
    /// 一大片空白（卡片底色和键盘底色几乎一样白，看着就是"空白太多"），该占空间的候选滚动区
    /// 反被挤成一条（"就只有一个东西"）。这里把各块在真实宽度下的高度加起来定高，190 起、470 封顶，
    /// 超出的部分才交给滚动。
    private func refit() {
        let avail = view.bounds.width - 24
        guard avail > 60, !fitBlocks.isEmpty else { return }
        var height: CGFloat = 6 + 36 + 6 + 8      // 上边距 + 顶栏 + 间距 + 下边距
        for (i, block) in fitBlocks.enumerated() {
            height += block.systemLayoutSizeFitting(
                CGSize(width: avail, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel).height
            if i < fitBlocks.count - 1 { height += 6 }
        }
        heightConstraint.constant = min(max(height, Self.minPanelHeight), maxPanelHeight) + containerGap
    }

    /// 面板高度下限。**不能低于系统键盘的最小高度**：实测请求 190pt 时，系统按自己的最小值
    /// （约 204pt）给键盘区域，我们的视图只有 190 又被贴底，上方那 14pt 就露出系统的圆角底衬
    /// ——看起来就是键盘顶上多了一条灰带（结果态高度够大，所以不带这个问题）。
    private static let minPanelHeight: CGFloat = 210

    /// 键盘面板上方那条"灰带"的成因排查（结论：不是缝隙，量出来容器与视图**等高**）。
    /// 这段保留作兜底：万一某个 App/机型上容器真的比视图高，就把视图补到容器高度、用背景盖住。
    /// 关键点：**必须等 frame 铺开后再量**——刚出现时 frame 是整屏尺寸（390x844），
    /// 拿它算会得到 0 并误标"已量过"，于是永远不再量（上一版就是这么失效的）。
    private func coverContainerGap() {
        guard !didMeasureContainerGap, let container = view.superview else { return }
        let containerHeight = container.bounds.height
        let viewHeight = view.bounds.height
        guard containerHeight > 0, viewHeight > 0,
              containerHeight < 600, viewHeight < 600 else { return }  // 还没铺开，下次再看
        didMeasureContainerGap = true
        let gap = containerHeight - viewHeight
        guard gap > 1, gap <= 60 else { return }
        containerGap = gap
        lastFit = nil
        refit()
#if DEBUG
        JevStore.diag(String(format: "补容器间隙 %.0fpt（容器 %.0f / 视图 %.0f）",
                             gap, containerHeight, viewHeight))
#endif
    }

    /// 面板上限跟着屏幕走：小屏（SE 667pt）上写死 470 会盖掉大半个屏幕，
    /// 大屏（Pro Max 932pt）上又不该浪费空间。取可用高度的 45%，夹在 [220, 470] 之间。
    /// 用窗口场景的坐标系而不是 UIScreen.bounds——后者恒为竖屏尺寸，横屏时会算多。
    private var maxPanelHeight: CGFloat {
        let scene = view.window?.windowScene
        let available = scene?.coordinateSpace.bounds.height ?? UIScreen.main.bounds.height
        return min(470, max(220, available * 0.45))
    }

#if DEBUG
    private func frameText(_ r: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }
#endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        coverContainerGap()               // 铺开后如果容器比视图高，就补高盖住（通常量到的是等高）
        let width = view.bounds.width
        guard width > 0, lastFit == nil || lastFit!.mode != mode || lastFit!.width != width else { return }
        lastFit = (mode, width)
        refit()
#if DEBUG
        // 顶部那条「色块」的取证（1）：我们视图与直接父视图的几何关系
        let supFrame = view.superview.map { frameText($0.frame) } ?? "nil"
        let supBounds = view.superview.map { frameText($0.bounds) } ?? "nil"
        JevStore.diag("几何 view=\(frameText(view.frame)) 父frame=\(supFrame) 父bounds=\(supBounds) 兄弟数=\(view.superview?.subviews.count ?? -1)")

        // 取证（2）：等键盘真正铺开后再往上数三层容器——iOS 26 的键盘容器自己画圆角底衬，
        // 得知道那一层是什么类、多大、什么颜色，才能判断那条带子是它的还是我们的
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            var parts: [String] = []
            var node: UIView? = self.view
            for _ in 0..<4 {
                guard let cur = node else { break }
                let bg = cur.backgroundColor.map { "\($0)" } ?? "nil"
                parts.append("\(type(of: cur)) \(frameText(cur.frame)) bg=\(bg)")
                node = cur.superview
            }
            JevStore.diag("容器链 " + parts.joined(separator: " | "))
        }
#endif
    }

    @objc private func switchKeyboard() { cancelRequest(); advanceToNextInputMode() }

    @objc private func deleteBackwardTapped() {
        textDocumentProxy.deleteBackward()
    }

#if DEBUG
    /// 自检入口：把面板直接切到某个状态渲染出来。
    /// 键盘本体不走这条路径；这是给独立预览壳工程用的——键盘扩展没法用脚本唤起，
    /// 靠它才能在模拟器上按不同机型尺寸看布局（见 /tmp 的 PanelPreview 壳）。
    func previewContextStore(_ store: JevContextDraftStore) { contextDraftStore = store }
    func previewAppendContext(_ text: String) { appendContextText(text) }
    func previewDocumentChange(_ id: UUID) { synchronizeDocument(with: id) }
    var previewContextTurnCount: Int { replyContext.turns.count }

    func previewPanel(_ kind: String, analysis: Analysis? = nil, errorText: String = "") {
        self.analysis = analysis
        self.errorText = errorText
        switch kind {
        case "gate": mode = .gate
        case "tones": mode = .tones
        case "context": restoreContextDraft(); mode = .context
        case "loading": mode = .loading
        case "result": mode = .result
        case "error": mode = .error
        default: mode = .idle
        }
        render()
    }
#endif

    // MARK: 状态渲染

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        fitBlocks = []
        lastFit = nil
        switch mode {
        case .gate: contentStack.addArrangedSubview(gateView())
        case .idle: contentStack.addArrangedSubview(idleView())
        case .tones: contentStack.addArrangedSubview(tonesView())
        case .context: contentStack.addArrangedSubview(contextView())
        case .refine: contentStack.addArrangedSubview(refinementView())
        case .loading: contentStack.addArrangedSubview(loadingView())
        case .result: contentStack.addArrangedSubview(resultView())
        case .error: contentStack.addArrangedSubview(errorView())
        }
    }

    private func setMode(_ m: Mode) {
        mode = m
        render()
    }

    // MARK: 门禁视图（没有完全访问时）

    private func gateView() -> UIView {
        let card = KB.cardView()
        let title = KB.label("需要「允许完全访问」", font: .systemFont(ofSize: 16, weight: .bold),
                             color: .systemRed)
        let steps = KB.label(
            "Jev 键盘要联网调用模型、读取剪贴板，这两项都要求完全访问：\n\n"
            + "① 打开系统「设置」→「通用」→「键盘」→「键盘」\n"
            + "② 点「添加新键盘」→ 选「Jev 键盘」\n"
            + "③ 点「Jev 键盘」→ 打开「允许完全访问」\n\n"
            + "完全访问意味着键盘能传输按键与剪贴板内容——本项目开源、只用你自己填的 API Key，"
            + "不用时可以在同页一键移除。",
            font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let vstack = UIStackView(arrangedSubviews: [title, steps])
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 待机视图

    private func idleView() -> UIView {
        let cfg = JevStore.loadConfig()

        let guide = KB.label(
            "长按对方消息 → 复制，再点下面的按钮",
            font: .systemFont(ofSize: 12), color: KB.secondaryText)

        let clipBtn = KB.button("分析剪贴板", icon: "doc.on.clipboard", primary: true,
                                font: .systemFont(ofSize: 14, weight: .semibold))
        clipBtn.addTarget(self, action: #selector(analyzeClipboard), for: .touchUpInside)

        let inputBtn = KB.button("AI 分析输入框文字", icon: "text.cursor",
                                 font: .systemFont(ofSize: 14, weight: .semibold))
        inputBtn.addTarget(self, action: #selector(analyzeInputField), for: .touchUpInside)

        // 两个分析入口并排：左边读剪贴板（主路径，主色），右边读当前输入框
        let btnRow = UIStackView(arrangedSubviews: [clipBtn, inputBtn])
        btnRow.axis = .horizontal
        btnRow.spacing = 8
        btnRow.distribution = .fillEqually
        btnRow.heightAnchor.constraint(equalToConstant: 44).isActive = true

        // 话术：点进去直接在键盘上选（写回共享配置，App 的「话术」页看到的是同一份）
        let tonesBtn = KB.button(
            cfg.activeSlots.isEmpty
                ? "话术：都没选（点这里选）"
                : "话术：" + cfg.activeSlots.joined(separator: " · "),
            icon: "theatermasks")
        tonesBtn.heightAnchor.constraint(equalToConstant: 34).isActive = true
        tonesBtn.addTarget(self, action: #selector(openTonePicker), for: .touchUpInside)

        // 待机页**不放**发送键：这一页还没有候选，没有可发的东西；而输入框一旦有字，
        // 宿主 App 自己的发送按钮就出来了（微信是「有内容时 + 变发送」），
        // 键盘下方再挂一个只是添乱。发送键只在结果页——点完候选、手还在面板上时用。
        let contextBtn = KB.button("上下文 · \(replyContext.scene) · \(replyContext.turns.count)/5 条", icon: "text.bubble")
        contextBtn.addAction(UIAction { [weak self] _ in
            self?.restoreContextDraft(); self?.setMode(.context)
        }, for: .touchUpInside)
        let vstack = UIStackView(arrangedSubviews: [guide, btnRow, tonesBtn, contextBtn])
        vstack.axis = .vertical
        vstack.spacing = 8
        if !cfg.generation.key.isEmpty {
            // 配置正常（含内置中转兜底）时不占行
        } else {
            let message = JevStore.groupWritable
                ? "⚠️ 还没配置生成层：打开 Jev Jarvis App →「模型」页填 API Key"
                : "⚠️ 共享配置不可用：请安装支持当前签名的版本，主 App 的 Key 无法同步到键盘"
            let warn = KB.label(message,
                                font: .systemFont(ofSize: 12), color: .systemOrange, lines: 0)
            vstack.addArrangedSubview(warn)
        }
        fitBlocks = [vstack]
        return vstack
    }

    // MARK: 话术选择视图（直接在键盘上配）

    @objc private func openTonePicker() { setMode(.tones) }

    /// 话术选择：内置 + 自定义全列出来，点一下选中/取消，最多 3 个槽。
    /// 每次从共享配置重新读（App 那边改过也能立刻看到），选中即落盘，下一次分析就生效。
    private func tonesView() -> UIView {
        let cfg = JevStore.loadConfig()
        let names = toneCategory.names(custom: cfg.customTones)
        let pageCount = max(1, (names.count + Self.tonesPerPage - 1) / Self.tonesPerPage)
        tonePage = min(max(0, tonePage), pageCount - 1)
        let pageNames = Array(names.dropFirst(tonePage * Self.tonesPerPage).prefix(Self.tonesPerPage))
        let active = cfg.activeSlots
        let total = orderedToneNames(custom: cfg.customTones).count

        let categories = UISegmentedControl(items: JevToneCategory.allCases.map(\.rawValue))
        categories.selectedSegmentIndex = JevToneCategory.allCases.firstIndex(of: toneCategory) ?? 0
        categories.accessibilityIdentifier = "tones.categories"
        categories.addAction(UIAction { [weak self, weak categories] _ in
            guard let self, let categories else { return }
            self.toneCategory = JevToneCategory.allCases[categories.selectedSegmentIndex]
            self.tonePage = 0
            self.render()
        }, for: .valueChanged)
        categories.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let title = KB.label("共 \(total) 种 · \(toneCategory.rawValue) \(names.count) 种 · 最多选 \(MAX_SLOTS) 种",
                             font: .systemFont(ofSize: 11), color: KB.secondaryText, lines: 1)
        title.accessibilityIdentifier = "tones.count"
        var blocks: [UIView] = [categories, title]
        var row: [UIView] = []
        for name in pageNames {
            let btn = KB.button(name, primary: active.contains(name), font: .systemFont(ofSize: 12, weight: .medium))
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
            btn.accessibilityIdentifier = name
            btn.accessibilityTraits = active.contains(name) ? [.button, .selected] : [.button]
            btn.addTarget(self, action: #selector(toneChipTapped(_:)), for: .touchUpInside)
            row.append(btn)
            if row.count == 3 { blocks.append(gridRow(row)); row = [] }
        }
        if !row.isEmpty {
            while row.count < 3 { row.append(UIView()) }
            blocks.append(gridRow(row))
        }

        let previous = KB.button("上一页", font: .systemFont(ofSize: 12))
        previous.accessibilityIdentifier = "tones.previous"
        previous.isEnabled = tonePage > 0
        previous.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.tonePage -= 1; self.render()
        }, for: .touchUpInside)
        let page = KB.label("\(tonePage + 1)/\(pageCount)", font: .systemFont(ofSize: 12), alignment: .center)
        page.accessibilityIdentifier = "tones.page"
        let next = KB.button("下一页", font: .systemFont(ofSize: 12))
        next.accessibilityIdentifier = "tones.next"
        next.isEnabled = tonePage + 1 < pageCount
        next.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.tonePage += 1; self.render()
        }, for: .touchUpInside)
        let done = KB.button("好了", icon: "checkmark", primary: true, font: .systemFont(ofSize: 12))
        done.accessibilityIdentifier = "tones.done"
        done.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let actions = gridRow([previous, page, next, done])
        actions.heightAnchor.constraint(equalToConstant: 34).isActive = true
        blocks.append(actions)
        let outer = UIStackView(arrangedSubviews: blocks)
        outer.axis = .vertical
        outer.spacing = 6
        fitBlocks = blocks
        return outer
    }

    private func gridRow(_ cells: [UIView]) -> UIStackView {
        let s = UIStackView(arrangedSubviews: cells)
        s.axis = .horizontal
        s.spacing = 6
        s.distribution = .fillEqually
        return s
    }

    @objc private func toneChipTapped(_ sender: UIButton) {
        guard let name = sender.accessibilityIdentifier else { return }
        var cfg = JevStore.loadConfig()
        var slots = cfg.slots
        while slots.count < MAX_SLOTS { slots.append(NONE_LABEL) }
        if let i = slots.firstIndex(of: name) {
            slots[i] = NONE_LABEL                      // 再点一下 = 取消
        } else if let free = slots.firstIndex(where: { $0.isEmpty || $0 == NONE_LABEL }) {
            slots[free] = name                         // 填进第一个空槽
        } else {
            slots[MAX_SLOTS - 1] = name                // 槽满了就顶掉最后一个
        }
        cfg.slots = Array(slots.prefix(MAX_SLOTS))
        JevStore.saveConfig(cfg)                       // 立刻落盘：下一次分析就用新槽位
        render()  // Preserve category and page while refreshing selection.
    }

    // MARK: 手动上下文（用户点添加才读取，暂存于本机缓存）

    private func restoreContextDraft() {
        replyContext = contextDraftStore.load()
    }

    private func appendContextText(_ text: String) {
        restoreContextDraft()
        do {
            var updated = replyContext
            try updated.append(text, speaker: contextSpeaker)
            try contextDraftStore.save(updated)
            replyContext = updated
            contextError = ""
        } catch { contextError = "未添加：" + error.localizedDescription }
        render()
    }

    private func contextView() -> UIView {
        let note = KB.label("逐条复制后点添加，切走键盘不会清空。草稿在本机保留 30 分钟；分析时发给模型，换聊天请清空。",
                            font: .systemFont(ofSize: 11), color: KB.secondaryText)
        let scenes = UISegmentedControl(items: JevReplyContext.scenes)
        scenes.selectedSegmentIndex = JevReplyContext.scenes.firstIndex(of: replyContext.scene) ?? 0
        scenes.addAction(UIAction { [weak self, weak scenes] _ in
            guard let self, let scenes else { return }
            self.restoreContextDraft()
            do {
                var updated = self.replyContext
                updated.scene = JevReplyContext.scenes[scenes.selectedSegmentIndex]
                try self.contextDraftStore.save(updated)
                self.replyContext = updated
                self.contextError = ""
            } catch { self.contextError = "场景未保存：" + error.localizedDescription }
            self.render()
        }, for: .valueChanged)
        let speaker = UISegmentedControl(items: JevReplyContext.Speaker.allCases.map(\.rawValue))
        speaker.selectedSegmentIndex = contextSpeaker == .other ? 0 : 1
        speaker.addAction(UIAction { [weak self, weak speaker] _ in
            self?.contextSpeaker = speaker?.selectedSegmentIndex == 1 ? .me : .other
        }, for: .valueChanged)
        let add = KB.button("添加剪贴板", icon: "plus", primary: true, font: .systemFont(ofSize: 13))
        add.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            guard self.hasFullAccess else { self.setMode(.gate); return }
            self.appendContextText(UIPasteboard.general.string ?? "")
        }, for: .touchUpInside)
        let controls = gridRow([speaker, add])
        controls.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let preview = replyContext.turns.enumerated().map {
            "\($0.offset + 1). \($0.element.speaker.rawValue)：\($0.element.text)"
        }.joined(separator: "\n\n")
        let body = KB.label(preview.isEmpty ? "还没有上下文（最多 5 条）" : preview,
                            font: .systemFont(ofSize: 12))
        body.accessibilityIdentifier = "context.preview"
        let status = KB.label(contextError.isEmpty ? "\(replyContext.turns.count)/5 条 · 本机暂存 30 分钟" : contextError,
                              font: .systemFont(ofSize: 11), color: contextError.isEmpty ? KB.secondaryText : .systemOrange)
        let clear = KB.button("清空", icon: "trash")
        clear.accessibilityIdentifier = "context.clear"
        clear.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            do {
                try self.contextDraftStore.clear()
                self.replyContext.clear()
                self.lastContext = nil
                self.analysis = nil
                self.contextError = ""
            } catch { self.contextError = "清空失败：" + error.localizedDescription }
            self.render()
        }, for: .touchUpInside)
        let done = KB.button("好了", icon: "checkmark", primary: true)
        done.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let actions = gridRow([clear, done])
        let details = UIStackView(arrangedSubviews: [note, scenes, controls, status, body])
        details.axis = .vertical
        details.spacing = 6
        let scroll = scrolling(details)
        let outer = UIStackView(arrangedSubviews: [scroll, actions])
        outer.axis = .vertical
        outer.spacing = 6
        actions.setContentCompressionResistancePriority(.required, for: .vertical)
        fitBlocks = [details, actions]
        return outer
    }

    private func scrolling(_ body: UIView) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return scroll
    }

    private func refinementView() -> UIView {
        guard let index = refinementIndex, let a = analysis, a.candidates.indices.contains(index) else { return UIView() }
        let note = KB.label("只改这一条，保留原意；生成后请核对内容。", font: .systemFont(ofSize: 12), color: KB.secondaryText)
        let body = KB.label(a.candidates[index].text, font: .systemFont(ofSize: 15))
        let scroll = scrolling(body)
        let buttons = JevReplyAdjustment.allCases.map { adjustment -> UIView in
            let button = KB.button(adjustment.rawValue, font: .systemFont(ofSize: 13))
            button.addAction(UIAction { [weak self] _ in self?.refine(adjustment) }, for: .touchUpInside)
            return button
        }
        let options = gridRow(buttons)
        options.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let back = KB.button("返回候选", icon: "chevron.left")
        back.addAction(UIAction { [weak self] _ in self?.setMode(.result) }, for: .touchUpInside)
        let outer = UIStackView(arrangedSubviews: [note, scroll, options, back])
        outer.axis = .vertical
        outer.spacing = 6
        fitBlocks = [note, body, options, back]
        return outer
    }

    private func refine(_ adjustment: JevReplyAdjustment) {
        guard hasFullAccess else { setMode(.gate); return }
        guard let index = refinementIndex, let snapshot = analysis,
              snapshot.candidates.indices.contains(index) else { return }
        cancelRequest()
        let candidate = snapshot.candidates[index]
        let id = requestGate.begin()
        let document = textDocumentProxy.documentIdentifier
        let context = lastContext
        let draft = JevDraft(cfg: JevStore.loadConfig())
        setMode(.loading)
        stageLabel.text = "正在改为「\(adjustment.rawValue)」…"
        generationTask = Task { @MainActor [weak self] in
            do {
                let text = try await draft.refine(message: snapshot.message, context: context,
                                                  candidate: candidate.text, adjustment: adjustment)
                guard let self, self.accepts(id, document: document), !Task.isCancelled else { return }
                self.requestGate.finish(id)
                self.generationTask = nil
                var result = snapshot
                result.rankingPending = false
                result.candidates[index].text = text
                result.candidates[index].prob = nil
                self.analysis = result
                self.setMode(.result)
                self.flashFooter("已微调，请核对后再插入", color: KB.riskColor(0))
            } catch {
                guard let self, self.accepts(id, document: document), !Task.isCancelled else { return }
                self.requestGate.finish(id)
                self.generationTask = nil
                self.setMode(.result)
                self.flashFooter("微调失败，已保留原候选：" + error.localizedDescription, color: .systemOrange)
            }
        }
    }

    // MARK: 加载视图

    private func loadingView() -> UIView {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        stageLabel = KB.label("分析中…", font: .systemFont(ofSize: 14), color: KB.secondaryText)
        let hstack = UIStackView(arrangedSubviews: [spinner, stageLabel])
        hstack.axis = .horizontal
        hstack.spacing = 10
        hstack.alignment = .center
        let card = KB.cardView()
        card.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            hstack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            card.heightAnchor.constraint(equalToConstant: 96),
        ])
        let stop = KB.button("停止生成", icon: "stop.fill")
        stop.addTarget(self, action: #selector(stopGeneration), for: .touchUpInside)
        let outer = UIStackView(arrangedSubviews: [card, stop])
        outer.axis = .vertical
        outer.spacing = 8
        fitBlocks = [card, stop]
        return outer
    }

    // MARK: 结果视图

    private func resultView() -> UIView {
        guard let a = analysis else { return UIView() }
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 5

        // 判断头
        let header = KB.cardView()
        var headerItems: [UIView] = []
        if let jr = a.judge {
            // 风险等级文案跟徽章同一行——它单独占一行太浪费高度（键盘面板寸土寸金）
            let riskText = KB.label(jr.riskLevelText, font: .systemFont(ofSize: 12),
                                    color: KB.riskColor(jr.risk), lines: 1)
            riskText.setContentHuggingPriority(.required, for: .horizontal)
            let chipRow = UIStackView(arrangedSubviews: [
                KB.badge(jr.intent, color: KB.brand),
                KB.badge(String(format: "风险 %.0f/9", jr.risk), color: KB.riskColor(jr.risk)),
                riskText,
                UIView(),   // 占位：吃掉余量，徽章和文案各自按内容 hug
            ])
            chipRow.axis = .horizontal
            chipRow.spacing = 8
            headerItems.append(chipRow)
            if !jr.actions.isEmpty {
                headerItems.append(KB.label("建议：" + jr.actions.joined(separator: " · "),
                                            font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0))
            }
        } else {
            headerItems.append(KB.label("未配置判断层，直接生成（可在 App 里开启）",
                                        font: .systemFont(ofSize: 12), color: KB.secondaryText))
        }
        let quoted = KB.label("「" + (a.message.count > 40 ? String(a.message.prefix(40)) + "…" : a.message) + "」",
                              font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 1)
        headerItems.append(quoted)
        let hstack = UIStackView(arrangedSubviews: headerItems)
        hstack.axis = .vertical
        hstack.spacing = 4
        hstack.isLayoutMarginsRelativeArrangement = true
        hstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        header.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: header.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        outer.addArrangedSubview(header)

        // 时间脚注（先建好：插入/发送的反馈要临时改它）
        let footer = KB.label(a.rankingPending
                                ? "候选已出 · 排序中…（现在就能点）"
                                : String(format: "%.1f 秒 · 点候选填入，再用聊天 App 发送", a.elapsed),
                              font: .systemFont(ofSize: 10), color: KB.secondaryText)
        flashTarget = footer

        // 候选列表（可滚动）。真没有候选时也要说一句话，别留给用户一片空白。
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        if a.candidates.isEmpty {
            list.addArrangedSubview(KB.label("这次没出候选，点「换一批」再试一次",
                                             font: .systemFont(ofSize: 13),
                                             color: KB.secondaryText, lines: 0))
        }
        for (index, c) in a.candidates.enumerated() {
            let row = CandidateRow(candidate: c)
            let document = textDocumentProxy.documentIdentifier
            row.onInsert = { [weak self] candidate in
                guard let self, self.hasFullAccess,
                      self.textDocumentProxy.documentIdentifier == document else { return }
                self.cancelRequest()
                self.textDocumentProxy.insertText(JevReplyText.singleLine(candidate.text))
                self.render()
                self.flashFooter("已填入，请检查后用聊天 App 发送", color: KB.riskColor(0))
            }
            let adjust = KB.button("微调", font: .systemFont(ofSize: 12))
            adjust.widthAnchor.constraint(equalToConstant: 52).isActive = true
            adjust.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            adjust.accessibilityLabel = "微调第 \(index + 1) 条回复"
            adjust.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.cancelRequest()
                self.refinementIndex = index
                self.setMode(.refine)
            }, for: .touchUpInside)
            let entry = UIStackView(arrangedSubviews: [row, adjust])
            entry.axis = .horizontal
            entry.spacing = 6
            list.addArrangedSubview(entry)
        }
        for n in a.notices.prefix(2) {
            list.addArrangedSubview(KB.label("· " + n, font: .systemFont(ofSize: 11),
                                             color: .systemOrange, lines: 0))
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        // 别让滚动视图拖延把触摸交给候选行——延迟投递正是"点了没反应"的常见来源
        scroll.delaysContentTouches = false
        scroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        outer.addArrangedSubview(scroll)

        // Only the host chat app owns sending.
        let regen = KB.button("换一批", icon: "arrow.clockwise")
        regen.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button("返回", icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        var actionButtons: [UIView] = [regen, close]
        if requestGate.currentID != nil {
            let stop = KB.button("停止", icon: "stop.fill")
            stop.addTarget(self, action: #selector(stopGeneration), for: .touchUpInside)
            actionButtons.append(stop)
        }
        let actions = gridRow(actionButtons)
        actions.axis = .horizontal
        actions.spacing = 8
        outer.addArrangedSubview(actions)
        outer.addArrangedSubview(footer)

        // 只让候选区伸缩：卡片/按钮都按内容 hug，否则会被多余的垂直空间拉出空白。
        header.setContentHuggingPriority(.required, for: .vertical)
        actions.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        fitBlocks = [header, list, actions, footer]
        return outer
    }

    /// 即时反馈：目标那行小字短暂变色改字。用户要一眼能确认「点到了 / 插进去了 / 发出去了」。
    private func flashFooter(_ text: String, color: UIColor) {
        guard let target = flashTarget else { return }
        let base = target.text
        target.textColor = color
        target.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak target] in
            target?.textColor = KB.secondaryText
            target?.text = base
        }
    }

    // MARK: 错误视图

    private func errorView() -> UIView {
        let card = KB.cardView()
        let title = KB.label("出错了", font: .systemFont(ofSize: 15, weight: .bold), color: .systemRed)
        let body = KB.label(errorText, font: .systemFont(ofSize: 13), color: KB.primaryText, lines: 0)
        let retry = KB.button("重试", icon: "arrow.clockwise")
        retry.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button("返回", icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let btns = UIStackView(arrangedSubviews: [retry, close])
        btns.axis = .horizontal
        btns.spacing = 8
        let vstack = UIStackView(arrangedSubviews: [title, body, btns])
        vstack.axis = .vertical
        vstack.spacing = 8
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        fitBlocks = [card]
        return card
    }

    // MARK: 动作

    @objc private func analyzeClipboard() {
        lastSource = .clipboard
        guard hasFullAccess else { setMode(.gate); return }
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            errorText = "剪贴板是空的。先在聊天里长按要回的消息 →「复制」，再回来点分析。"
            setMode(.error)
            return
        }
        run(message: text)
    }

    @objc private func analyzeInputField() {
        lastSource = .inputField
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let text = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorText = "输入框里没有文字。这个按钮分析的是当前输入框里已输入的内容（比如你打了一半拿不准的话）。"
            setMode(.error)
            return
        }
        run(message: text)
    }

    @objc private func regenerate() { run(message: lastMessage) }
    @objc private func backToIdle() { cancelRequest(); setMode(.idle) }

    private func run(message: String) {
        synchronizeDocument()
        cancelRequest()
        guard hasFullAccess else { setMode(.gate); return }
        guard JevStore.groupWritable else {
            errorText = "键盘无法访问共享配置。请确认 App 和键盘使用同一 Team、同一 App Group，并使用适配重签组名的版本。"
            setMode(.error)
            return
        }
        reportConfigurationStatus()
        lastMessage = message
        restoreContextDraft()
        lastContext = replyContext.promptContext
        let context = lastContext
        analysis = nil
        let id = requestGate.begin()
        let document = textDocumentProxy.documentIdentifier
        setMode(.loading)
        stageLabel.text = "判断中…"
        let pipeline = JevPipeline(cfg: JevStore.loadConfig())

        generationTask = Task { @MainActor [weak self] in
            let analysis = await pipeline.analyze(
                message: message, context: context,
                onStage: { [weak self] stage in
                    Task { @MainActor in
                        guard let self, self.accepts(id, document: document) else { return }
                        switch stage {
                        case .judging: self.stageLabel.text = "判断中…"
                        case .drafting(let done, let total):
                            self.stageLabel.text = "生成中 \(done)/\(total)…"
                        case .ranking: self.stageLabel.text = "排序中…"
                        case .done: self.stageLabel.text = "完成"
                        }
                    }
                },
                onPartial: { [weak self] partial in
                    // 第一条话术的候选一到就先出面板，不等其余话术、更不等排序。
                    // 请求标识也区分同一条消息的多次生成。
                    Task { @MainActor in
                        guard let self, self.accepts(id, document: document) else { return }
                        self.analysis = partial
                        self.setMode(.result)
                    }
                })
            guard let self, self.accepts(id, document: document), !Task.isCancelled else { return }
            self.requestGate.finish(id)
            self.generationTask = nil
            self.analysis = analysis
            if let fatal = analysis.fatalError {
                self.errorText = fatal
                self.setMode(.error)
            } else {
                self.setMode(.result)
            }
        }
    }
}
