import SwiftUI

/// 话术页：3 个槽位选语气 + 自定义话术。与 macOS 版悬浮窗下拉同语义。
struct TonesView: View {
    @EnvironmentObject private var store: ConfigStore
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                slotsSection
                customSection
                previewSection
            }
            .navigationTitle("话术")
            .sheet(isPresented: $showAdd) { AddToneView() }
        }
    }

    private var slotOptions: [String] {
        [NONE_LABEL] + store.toneCatalog.keys.sorted { lhs, rhs in
            toneOrder(lhs) < toneOrder(rhs)
        }
    }

    /// 内置话术按 styles.py 的顺序展示，自定义排后面
    private func toneOrder(_ name: String) -> Int {
        BUILTIN_TONE_ORDER.firstIndex(of: name) ?? (BUILTIN_TONE_ORDER.count + 1)
    }

    private var slotsSection: some View {
        Section {
            ForEach(0..<MAX_SLOTS, id: \.self) { i in
                Picker("槽位 \(i + 1)", selection: slotBinding(i)) {
                    ForEach(slotOptions, id: \.self) { Text($0).tag($0) }
                }
            }
        } header: {
            Text("槽位（每个话术每次出 2 条）")
        } footer: {
            Text("「\(NONE_LABEL)」= 该槽关闭。键盘上候选按槽位顺序展示，最多 \(MAX_SLOTS) 槽 × 2 条。")
        }
    }

    private func slotBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { store.config.slots.indices.contains(i) ? store.config.slots[i] : NONE_LABEL },
            set: { newValue in
                while store.config.slots.count < MAX_SLOTS { store.config.slots.append(NONE_LABEL) }
                store.config.slots = Array(store.config.slots.prefix(MAX_SLOTS))  // 丢掉超额的历史槽位
                store.config.slots[i] = newValue
            }
        )
    }

    private var customSection: some View {
        Section {
            ForEach(store.config.customTones.keys.sorted(), id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.subheadline.weight(.medium))
                    Text(store.config.customTones[name] ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { offsets in
                let keys = store.config.customTones.keys.sorted()
                for idx in offsets where keys.indices.contains(idx) {
                    store.config.customTones[keys[idx]] = nil
                }
            }
            Button {
                showAdd = true
            } label: {
                Label("添加自定义话术", systemImage: "plus")
            }
        } header: {
            Text("自定义话术")
        } footer: {
            Text("说明写清「什么语气 + 别变成什么」最管用（同 macOS 版 JEV_TONES 的建议）。同名覆盖内置。")
        }
    }

    private var previewSection: some View {
        Section("内置话术预览") {
            ForEach(Array(BUILTIN_TONES.keys.enumerated()), id: \.offset) { _, name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.subheadline.weight(.medium))
                    Text(BUILTIN_TONES[name] ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AddToneView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var desc = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("名字（下拉里显示的）", text: $name)
                TextField("说明（什么语气 + 别变成什么）", text: $desc, axis: .vertical)
                    .lineLimit(3...6)
            }
            .navigationTitle("自定义话术")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let d = desc.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty, !d.isEmpty, n != NONE_LABEL else { return }
                        store.config.customTones[n] = d
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              desc.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
