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

    private enum Mode { case gate, idle, loading, result, error }

    private var mode: Mode = .idle
    private var lastSource: Source = .clipboard
    private var lastMessage: String = ""
    private var analysis: Analysis?
    private var errorText: String = ""
    private var stageLabel = UILabel()

    private enum Source { case clipboard, inputField }

    // MARK: 布局骨架

    private let topBar = UIView()
    private var statusLabel = UILabel()
    private let contentStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = KB.bg
        view.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)

        buildTopBar()
        buildContentStack()
        mode = hasFullAccess ? .idle : .gate
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 回写状态：主 App「开始」页据此显示键盘是否已启用、是否给了完全访问
        JevStore.saveKeyboardStatus(KeyboardStatus(lastSeen: Date(), hasFullAccess: hasFullAccess))
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

        statusLabel = KB.label(hasFullAccess ? "Jev · 已连接" : "Jev · 需要完全访问",
                               font: .systemFont(ofSize: 12, weight: .medium), color: KB.secondaryText)

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
            topBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            title.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            hstack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            hstack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
        ])
    }

    private func buildContentStack() {
        contentStack.axis = .vertical
        contentStack.spacing = 8
        view.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            view.heightAnchor.constraint(equalToConstant: 320),
        ])
    }

    @objc private func switchKeyboard() { advanceToNextInputMode() }
    @objc private func deleteBackwardTapped() {
        textDocumentProxy.deleteBackward()
    }

    // MARK: 状态渲染

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch mode {
        case .gate: contentStack.addArrangedSubview(gateView())
        case .idle: contentStack.addArrangedSubview(idleView())
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
        vstack.spacing = 10
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    // MARK: 待机视图

    private func idleView() -> UIView {
        let cfg = JevStore.loadConfig()

        let guide = KB.label(
            "长按对方消息 → 复制，再点下面的按钮",
            font: .systemFont(ofSize: 12), color: KB.secondaryText)

        let clipBtn = KB.button("分析剪贴板", icon: "doc.on.clipboard", primary: true,
                                font: .systemFont(ofSize: 17, weight: .semibold))
        clipBtn.heightAnchor.constraint(equalToConstant: 46).isActive = true
        clipBtn.addTarget(self, action: #selector(analyzeClipboard), for: .touchUpInside)

        let inputBtn = KB.button("分析输入框文字", icon: "text.cursor")
        inputBtn.heightAnchor.constraint(equalToConstant: 36).isActive = true
        inputBtn.addTarget(self, action: #selector(analyzeInputField), for: .touchUpInside)

        let tonesLine = KB.label(
            cfg.activeSlots.isEmpty
                ? "话术槽都是「不用」，到 App 里启用"
                : "话术：" + cfg.activeSlots.joined(separator: " · "),
            font: .systemFont(ofSize: 11), color: KB.secondaryText)

        let vstack = UIStackView(arrangedSubviews: [guide, clipBtn, inputBtn, tonesLine])
        vstack.axis = .vertical
        vstack.spacing = 8
        if !cfg.generation.key.isEmpty {
            // 配置正常（含内置中转兜底）时不占行
        } else {
            let warn = KB.label("⚠️ 还没配置生成层：打开 Jev Jarvis App →「模型」页填 API Key",
                                font: .systemFont(ofSize: 12), color: .systemOrange, lines: 0)
            vstack.addArrangedSubview(warn)
        }
        return vstack
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
            card.heightAnchor.constraint(equalToConstant: 200),
        ])
        return card
    }

    // MARK: 结果视图

    private func resultView() -> UIView {
        guard let a = analysis else { return UIView() }
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 8

        // 判断头
        let header = KB.cardView()
        var headerItems: [UIView] = []
        if let jr = a.judge {
            let chipRow = UIStackView(arrangedSubviews: [
                KB.badge(jr.intent, color: KB.brand),
                KB.badge(String(format: "风险 %.0f/9", jr.risk), color: KB.riskColor(jr.risk)),
            ])
            chipRow.axis = .horizontal
            chipRow.spacing = 8
            headerItems.append(chipRow)
            headerItems.append(KB.label(jr.riskLevelText, font: .systemFont(ofSize: 13),
                                        color: KB.riskColor(jr.risk)))
            if !jr.actions.isEmpty {
                headerItems.append(KB.label("建议：" + jr.actions.joined(separator: " · "),
                                            font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 0))
            }
        } else {
            headerItems.append(KB.label("未配置判断层，直接生成（可在 App 里开启）",
                                        font: .systemFont(ofSize: 12), color: KB.secondaryText))
        }
        let quoted = KB.label("「" + (a.message.count > 40 ? String(a.message.prefix(40)) + "…" : a.message) + "」",
                              font: .systemFont(ofSize: 12), color: KB.secondaryText, lines: 2)
        headerItems.append(quoted)
        let hstack = UIStackView(arrangedSubviews: headerItems)
        hstack.axis = .vertical
        hstack.spacing = 6
        hstack.isLayoutMarginsRelativeArrangement = true
        hstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        header.addSubview(hstack)
        hstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: header.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
        ])
        outer.addArrangedSubview(header)

        // 候选列表（可滚动）
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 6
        for c in a.candidates {
            let row = CandidateRow(candidate: c)
            row.onInsert = { [weak self] candidate in
                self?.textDocumentProxy.insertText(candidate.text)
            }
            list.addArrangedSubview(row)
        }
        for n in a.notices.prefix(2) {
            list.addArrangedSubview(KB.label("· " + n, font: .systemFont(ofSize: 11),
                                             color: .systemOrange, lines: 0))
        }
        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
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

        // 底部操作
        let regen = KB.button("换一批", icon: "arrow.clockwise")
        regen.addTarget(self, action: #selector(regenerate), for: .touchUpInside)
        let close = KB.button("返回", icon: "chevron.left")
        close.addTarget(self, action: #selector(backToIdle), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [regen, close, UIView()])
        actions.axis = .horizontal
        actions.spacing = 8
        outer.addArrangedSubview(actions)

        // 时间脚注
        outer.addArrangedSubview(KB.label(String(format: "%.1f 秒 · 候选点按即插入，发送由你手动完成", a.elapsed),
                                          font: .systemFont(ofSize: 10), color: KB.secondaryText))
        return outer
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
        vstack.spacing = 10
        vstack.isLayoutMarginsRelativeArrangement = true
        vstack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        card.addSubview(vstack)
        vstack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: card.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
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
    @objc private func backToIdle() { setMode(.idle) }

    private func run(message: String) {
        lastMessage = message
        setMode(.loading)
        stageLabel.text = "判断中…"
        let pipeline = JevPipeline(cfg: JevStore.loadConfig())

        Task { @MainActor [weak self] in
            let analysis = await pipeline.analyze(message: message, context: nil) { [weak self] stage in
                Task { @MainActor in
                    switch stage {
                    case .judging: self?.stageLabel.text = "判断中…"
                    case .drafting(let done, let total):
                        self?.stageLabel.text = "生成中 \(done)/\(total)…"
                    case .ranking: self?.stageLabel.text = "排序中…"
                    case .done: self?.stageLabel.text = "完成"
                    }
                }
            }
            self?.analysis = analysis
            if let fatal = analysis.fatalError {
                self?.errorText = fatal
                self?.setMode(.error)
            } else {
                self?.setMode(.result)
            }
        }
    }
}
