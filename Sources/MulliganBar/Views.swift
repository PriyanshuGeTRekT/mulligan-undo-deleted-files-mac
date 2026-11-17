import SwiftUI
import AppKit
import MulliganCore

enum PathDisplay {
    /// Used when rendering demo screenshots, so temp folders show up as `~`.
    nonisolated(unsafe) static var prefixes: [(String, String)] = []
}

func tildePath(_ p: String) -> String {
    for (from, to) in PathDisplay.prefixes where p.hasPrefix(from) { return to + p.dropFirst(from.count) }
    return (p as NSString).abbreviatingWithTildeInPath
}

struct PopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if model.needsOnboarding {
                    OnboardingView(model: model)
                } else {
                    HeaderView(model: model)
                    ForEach(model.alerts) { AlertBanner(model: model, alert: $0) }
                    TabBar(model: model)
                    Divider()
                    switch model.tab {
                    case .deleted: DeletedListView(model: model)
                    case .search: SearchView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
            }
            if let m = model.message {
                Text(m)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color(nsColor: .labelColor).opacity(0.88)))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.bottom, 14)
            }
        }
        .frame(width: 420, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - header

struct HeaderView: View {
    @ObservedObject var model: AppModel

    var statusText: String {
        let s = model.status
        if s.scanning { return "Checking your files…" }
        if model.config.paused { return "Paused — changes are not being saved" }
        if !model.isWatcher { return "Another Mulligan is already watching" }
        if s.roots.isEmpty { return "Choose folders to protect" }
        let n = s.stats.liveFiles
        return "Protecting \(n.formatted()) file\(n == 1 ? "" : "s") in \(s.roots.count) folder\(s.roots.count == 1 ? "" : "s")"
    }

    var statusColor: Color {
        if model.config.paused { return .orange }
        if !model.isWatcher || model.status.roots.isEmpty { return .gray }
        return .green
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.96), Color(red: 0.25, green: 0.55, blue: 0.98)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "arrow.uturn.backward").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mulligan").font(.system(size: 14, weight: .bold))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.togglePause() } label: {
                Image(systemName: model.config.paused ? "play.fill" : "pause.fill").frame(width: 20, height: 20)
            }
            .help(model.config.paused ? "Resume protecting" : "Pause (for private work)")
            .accessibilityLabel(model.config.paused ? "Resume protecting" : "Pause protecting")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }
}

struct AlertBanner: View {
    @ObservedObject var model: AppModel
    let alert: AlertRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(alert.count.formatted()) files just disappeared from \(Fs.lastComponent(alert.root))")
                        .font(.system(size: 13, weight: .semibold))
                    Text(alert.detail.replacingOccurrences(of: "\n", with: ", ") + (alert.count > 5 ? " …" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                Button("Restore all \(alert.count.formatted())") { model.restoreAll(for: alert) }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                Button("It was me") { model.dismiss(alert) }.controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.red.opacity(0.35)))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

struct TabBar: View {
    @ObservedObject var model: AppModel

    func label(_ t: AppModel.Tab) -> String {
        t == .deleted && !model.deleted.isEmpty ? "Deleted (\(model.deleted.count))" : t.rawValue
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.Tab.allCases) { t in
                Button { model.tab = t } label: {
                    Text(label(t))
                        .font(.system(size: 12, weight: model.tab == t ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(model.tab == t ? Color.accentColor.opacity(0.16) : Color.clear))
                        .foregroundStyle(model.tab == t ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }
}

// MARK: - deleted list

struct DeletedListView: View {
    @ObservedObject var model: AppModel

    var groups: [(String, [DeletedItem])] {
        let now = Date(), cal = Calendar.current
        func label(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            return now.timeIntervalSince(d) < 7 * 86400 ? "Earlier this week" : "Older"
        }
        var out: [(String, [DeletedItem])] = []
        for it in model.deleted {
            let l = label(it.deletedAt)
            if let i = out.firstIndex(where: { $0.0 == l }) { out[i].1.append(it) } else { out.append((l, [it])) }
        }
        return out
    }

    var body: some View {
        if model.deleted.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "checkmark.shield.fill").font(.system(size: 38)).foregroundStyle(.green)
                Text("Nothing has been deleted lately").font(.system(size: 14, weight: .semibold))
                Text("If a file disappears — from you, an app, or a script — it will show up here, ready to restore.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { g in
                        Text(g.0.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                        ForEach(g.1) { item in
                            DeletedRow(item: item, onRestore: { model.restore([item]) })
                                .contextMenu {
                                    Button("Restore") { model.restore([item]) }
                                    Button("Show original folder") { model.revealOriginalFolder(item) }
                                    Divider()
                                    Button("Erase from Mulligan…") { model.erase(item) }
                                }
                        }
                    }
                    Text("Deleted files stay recoverable for \(model.config.keepDeletedDays) days.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
            }
        }
    }
}

struct DeletedRow: View {
    let item: DeletedItem
    let onRestore: () -> Void

    var detail: String {
        var s = "\(tildePath(item.file.folder)) · \(Fmt.bytes(item.latest.size)) · \(Fmt.ago(item.deletedAt))"
        if item.file.deletedKind == 1 { s += " · moved out" }
        return s
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: FileIcons.icon(for: item.file.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            Button("Restore", action: onRestore).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - search

struct SearchView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a file by name — deleted or not", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            .padding(12)

            if model.query.trimmingCharacters(in: .whitespaces).count < 2 {
                hint("Type part of a file name or folder.\nEvery saved version is listed, so you can go back to an earlier one.")
            } else if model.results.isEmpty {
                hint("Nothing saved matches “\(model.query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.results) { item in
                            SearchRow(model: model, item: item)
                        }
                    }
                }
            }
        }
    }

    func hint(_ text: String) -> some View {
        VStack { Spacer(); Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 36); Spacer() }
            .frame(maxWidth: .infinity)
    }
}

struct SearchRow: View {
    @ObservedObject var model: AppModel
    let item: DeletedItem

    var isDeleted: Bool { item.file.deletedAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.toggleExpand(item) } label: {
                HStack(spacing: 10) {
                    Image(nsImage: FileIcons.icon(for: item.file.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.file.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text(isDeleted ? "deleted" : "on disk")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(isDeleted ? Color.red.opacity(0.15) : Color.green.opacity(0.15)))
                                .foregroundStyle(isDeleted ? Color.red : Color.green)
                        }
                        Text(tildePath(item.file.folder)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Image(systemName: model.expanded.contains(item.file.id) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.expanded.contains(item.file.id) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.versionsByFile[item.file.id] ?? [], id: \.id) { v in
                        HStack {
                            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(Fmt.stamp(v.takenAt)).font(.system(size: 12))
                            Text(Fmt.bytes(v.size)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(isDeleted ? "Restore" : "Restore copy") { model.restore(v, alongside: !isDeleted) }
                                .controlSize(.small)
                        }
                        .padding(.leading, 52).padding(.trailing, 14).padding(.vertical, 3)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - settings

struct SettingsView: View {
    @ObservedObject var model: AppModel

    func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    var heldText: String {
        "Holding up to \(Fmt.bytes(model.status.stats.heldBytes)) for deleted files and older versions (limit \(Fmt.bytes(model.status.budgetBytes)))."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                card("Protected folders") {
                    ForEach(model.config.roots, id: \.self) { r in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                            Text(tildePath(r)).font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button { model.removeFolder(r) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Stop protecting \(Fs.lastComponent(r))")
                        }
                    }
                    if model.config.roots.isEmpty { Text("No folders yet.").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Button("Add folder…") { model.addFolder() }.controlSize(.small)
                }
                card("How long to keep things") {
                    HStack {
                        Text("Deleted files").font(.system(size: 12))
                        Spacer()
                        Picker("", selection: Binding(get: { model.config.keepDeletedDays }, set: { v in model.update { $0.keepDeletedDays = v } })) {
                            ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                    HStack {
                        Text("Earlier versions of files").font(.system(size: 12))
                        Spacer()
                        Picker("", selection: Binding(get: { model.config.keepHistoryDays }, set: { v in model.update { $0.keepHistoryDays = v } })) {
                            ForEach([3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
                        }.labelsHidden().frame(width: 110)
                    }
                }
                card("Disk space") {
                    Text(heldText).font(.system(size: 12))
                    Text("Copies cost nothing until a file changes or is deleted. When your disk runs low, Mulligan gives space back automatically, oldest first.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Check folders now") { model.scanNow() }.controlSize(.small)
                        Button("Free up space now") { model.freeSpaceNow() }.controlSize(.small)
                    }
                }
                card("General") {
                    Toggle("Alert me when many files disappear at once", isOn: Binding(get: { model.config.notify }, set: { v in model.update { $0.notify = v } }))
                        .font(.system(size: 12))
                    Toggle("Open Mulligan at login", isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLaunchAtLogin($0) }))
                        .font(.system(size: 12))
                }
                if model.noBackup {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
                        Text("Time Machine has no backup disk. Mulligan undoes deletions and mistakes, but it isn't a backup: if this Mac's disk fails or is stolen, the saved copies go with it.")
                            .font(.system(size: 11))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
                }
            }
            .padding(12)
        }
    }
}

// MARK: - onboarding

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.96), Color(red: 0.25, green: 0.55, blue: 0.98)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "arrow.uturn.backward").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            Text("A do-over for your files").font(.system(size: 20, weight: .bold))
            Text("Mulligan keeps an instant copy of every file as it changes. Delete something, save over it, or let a script or an AI assistant run wild — you can always get it back.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 8) {
                Text("PROTECT THESE FOLDERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(model.onboardingChoices.keys.sorted(), id: \.self) { p in
                    Toggle(isOn: Binding(get: { model.onboardingChoices[p] ?? false }, set: { model.onboardingChoices[p] = $0 })) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                            Text(tildePath(p)).font(.system(size: 12))
                        }
                    }
                }
                Button("Add another folder…") { model.addFolder() }.controlSize(.small)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            .padding(.horizontal, 20)

            Text("macOS will ask whether Mulligan may access these folders. Choose Allow.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("Start protecting") { model.finishOnboarding() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.onboardingChoices.values.contains(true))
            Spacer(minLength: 8)
        }
    }
}
