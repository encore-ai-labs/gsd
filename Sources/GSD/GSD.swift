import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - App Entry Point

@main
struct GSD {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var eventMonitor: Any?
    var hotKeyManager = HotKeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAtLogin.migrateIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "GSD")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: NoteView()
        )

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            if let popover = self?.popover, popover.isShown {
                popover.performClose(nil)
            }
        }

        // Register Cmd+0 global hotkey
        hotKeyManager.register(
            keyCode: UInt32(kVK_ANSI_0),
            modifiers: UInt32(cmdKey)
        ) { [weak self] in
            self?.togglePopover()
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Bring our app to front so the popover can become key
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Global Hotkey (Carbon)

class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var callback: (() -> Void)?

    // Static storage so the C function pointer can reach back into Swift
    private static var instance: HotKeyManager?

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        callback = handler
        HotKeyManager.instance = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, _) -> OSStatus in
                DispatchQueue.main.async {
                    HotKeyManager.instance?.callback?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: 0x444E4F54, id: 1)
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// MARK: - Launch at Login

struct LaunchAtLogin {
    private static let label = "com.gsd.app"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Migrate old com.dailynote.app LaunchAgent to new label.
    static func migrateIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let oldPlist = home.appendingPathComponent("Library/LaunchAgents/com.dailynote.app.plist")
        if fm.fileExists(atPath: oldPlist.path) {
            let wasEnabled = true // It existed, so it was enabled
            try? fm.removeItem(at: oldPlist)
            if wasEnabled && !isEnabled {
                toggle() // Re-register under new label
            }
        }
    }

    static func toggle() {
        if isEnabled {
            try? FileManager.default.removeItem(at: plistURL)
        } else {
            // Resolve the running executable's absolute path
            let execPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardized.path

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [execPath],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]

            // Ensure LaunchAgents directory exists
            let dir = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            {
                try? data.write(to: plistURL)
            }
        }
    }
}

// MARK: - Note Storage

class NoteStore: ObservableObject {
    @Published var text: String = ""
    @Published var currentDate: Date = Date()
    @Published var datesWithNotes: Set<DateComponents> = []
    @Published var notebooks: [String] = []
    @Published var currentNotebook: String = "Daily"

    private let baseDir: URL
    private var saveTask: DispatchWorkItem?

    static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let calendar = Calendar.current

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".gsd")
        let fm = FileManager.default

        // Migrate from ~/.dailynote/ to ~/.gsd/
        let legacyDailyNote = home.appendingPathComponent(".dailynote")
        if fm.fileExists(atPath: legacyDailyNote.path) && !fm.fileExists(atPath: baseDir.path) {
            try? fm.moveItem(at: legacyDailyNote, to: baseDir)
        }

        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Migrate from legacy ~/.daily/
        let legacyDir = home.appendingPathComponent(".daily")
        let dailyDir = baseDir.appendingPathComponent("Daily")
        if fm.fileExists(atPath: legacyDir.path) && !fm.fileExists(atPath: dailyDir.path) {
            try? fm.moveItem(at: legacyDir, to: dailyDir)
        }

        try? fm.createDirectory(at: dailyDir, withIntermediateDirectories: true)

        currentNotebook = loadLastNotebook()
        notebooks = scanNotebooks()
        if !notebooks.contains(currentNotebook) {
            currentNotebook = "Daily"
        }

        // Load today's note, applying carry-forward template if empty
        let loaded = loadFile(for: currentDate)
        if loaded.isEmpty {
            text = generateCarryForward(for: currentDate)
            if !text.isEmpty { scheduleSave() }
        } else {
            text = loaded
        }

        scanExistingNotes()
    }

    // MARK: - Notebook management

    var storageDir: URL {
        baseDir.appendingPathComponent(currentNotebook)
    }

    func scanNotebooks() -> [String] {
        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: baseDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return ["Daily"] }

        return contents.compactMap { url in
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue ? url.lastPathComponent : nil
        }.sorted()
    }

    func switchNotebook(to name: String) {
        save()
        currentNotebook = name
        saveLastNotebook(name)

        let loaded = loadFile(for: currentDate)
        if loaded.isEmpty && Self.calendar.isDateInToday(currentDate) {
            text = generateCarryForward(for: currentDate)
            if !text.isEmpty { scheduleSave() }
        } else {
            text = loaded
        }

        scanExistingNotes()
    }

    func createNotebook(name: String) {
        let dir = baseDir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        notebooks = scanNotebooks()
        switchNotebook(to: name)
    }

    func deleteNotebook(name: String) {
        guard name != "Daily" else { return }
        let dir = baseDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dir)
        notebooks = scanNotebooks()
        if currentNotebook == name {
            switchNotebook(to: "Daily")
        }
    }

    private func loadLastNotebook() -> String {
        let prefFile = baseDir.appendingPathComponent(".last-notebook")
        return
            (try? String(contentsOf: prefFile, encoding: .utf8).trimmingCharacters(
                in: .whitespacesAndNewlines)) ?? "Daily"
    }

    private func saveLastNotebook(_ name: String) {
        let prefFile = baseDir.appendingPathComponent(".last-notebook")
        try? name.write(to: prefFile, atomically: true, encoding: .utf8)
    }

    // MARK: - Date / file helpers

    var dateString: String {
        Self.fileFormatter.string(from: currentDate)
    }

    var isToday: Bool {
        Self.calendar.isDateInToday(currentDate)
    }

    var currentFilePath: URL {
        filePath(for: currentDate)
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var characterCount: Int {
        text.count
    }

    private func filePath(for date: Date) -> URL {
        let name = Self.fileFormatter.string(from: date)
        return storageDir.appendingPathComponent("\(name).md")
    }

    func loadFile(for date: Date) -> String {
        let path = filePath(for: date)
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    func save() {
        let path = filePath(for: currentDate)
        let dc = Self.calendar.dateComponents([.year, .month, .day], from: currentDate)

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: path)
            datesWithNotes.remove(dc)
            return
        }
        try? text.write(to: path, atomically: true, encoding: .utf8)
        datesWithNotes.insert(dc)
    }

    func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    // MARK: - Navigation

    func navigateTo(date: Date) {
        save()
        currentDate = date

        let loaded = loadFile(for: date)
        if loaded.isEmpty && Self.calendar.isDateInToday(date) {
            text = generateCarryForward(for: date)
            if !text.isEmpty { scheduleSave() }
        } else {
            text = loaded
        }
    }

    func goToPreviousDay() {
        if let prev = Self.calendar.date(byAdding: .day, value: -1, to: currentDate) {
            navigateTo(date: prev)
        }
    }

    func goToNextDay() {
        if let next = Self.calendar.date(byAdding: .day, value: 1, to: currentDate) {
            navigateTo(date: next)
        }
    }

    func goToToday() {
        navigateTo(date: Date())
    }

    func refreshIfNeeded() {
        if isToday { return }
    }

    func scanExistingNotes() {
        let dir = storageDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var found = Set<DateComponents>()
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files {
                    let name = file.deletingPathExtension().lastPathComponent
                    if let date = Self.fileFormatter.date(from: name) {
                        let dc = Self.calendar.dateComponents([.year, .month, .day], from: date)
                        found.insert(dc)
                    }
                }
            }
            DispatchQueue.main.async {
                self.datesWithNotes = found
            }
        }
    }

    func hasNote(for dateComponents: DateComponents) -> Bool {
        datesWithNotes.contains(dateComponents)
    }

    // MARK: - Carry-forward template

    /// Finds the most recent previous note (up to 30 days back).
    private func mostRecentPreviousNote(before date: Date) -> String? {
        for offset in 1...30 {
            guard let prevDate = Self.calendar.date(byAdding: .day, value: -offset, to: date) else {
                continue
            }
            let content = loadFile(for: prevDate)
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
        }
        return nil
    }

    /// Extracts tasks from the "## Today" section if it exists, otherwise from the whole note.
    private func extractTasks(from text: String) -> (checked: [String], unchecked: [String]) {
        let lines = text.components(separatedBy: "\n")

        // Find "## Today" section bounds
        var sectionStart: Int? = nil
        var sectionEnd: Int? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## Today" {
                sectionStart = i + 1
            } else if sectionStart != nil && sectionEnd == nil && trimmed.hasPrefix("## ") {
                sectionEnd = i
            }
        }

        let searchLines: ArraySlice<String>
        if let start = sectionStart {
            searchLines = lines[start..<(sectionEnd ?? lines.count)]
        } else {
            searchLines = lines[0..<lines.count]
        }

        var checked: [String] = []
        var unchecked: [String] = []

        for line in searchLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                checked.append(String(trimmed.dropFirst(6)))
            } else if trimmed.hasPrefix("- [ ] ") {
                let task = String(trimmed.dropFirst(6))
                if !task.trimmingCharacters(in: .whitespaces).isEmpty {
                    unchecked.append(task)
                }
            }
        }

        return (checked, unchecked)
    }

    /// Generates the carry-forward template for today.
    func generateCarryForward(for date: Date) -> String {
        guard Self.calendar.isDateInToday(date) else { return "" }
        guard let prevText = mostRecentPreviousNote(before: date) else { return "" }

        let (checked, unchecked) = extractTasks(from: prevText)
        if checked.isEmpty && unchecked.isEmpty { return "" }

        var template = ""

        if !checked.isEmpty {
            template += "## Done yesterday\n"
            for item in checked {
                template += "- [x] \(item)\n"
            }
            template += "\n---\n\n"
        }

        template += "## Today\n"
        for item in unchecked {
            template += "- [ ] \(item)\n"
        }

        return template
    }

    // MARK: - Checkbox toggling

    func toggleCheckbox(atLine lineIndex: Int) {
        var lines = text.components(separatedBy: "\n")
        guard lineIndex < lines.count else { return }

        let line = lines[lineIndex]
        if line.contains("- [ ]") {
            lines[lineIndex] = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
        } else if line.contains("- [x]") || line.contains("- [X]") {
            lines[lineIndex] = line
                .replacingOccurrences(of: "- [x]", with: "- [ ]")
                .replacingOccurrences(of: "- [X]", with: "- [ ]")
        }
        text = lines.joined(separator: "\n")
        scheduleSave()
    }

    // MARK: - Add task

    func addTask(_ taskText: String) {
        let newTask = "- [ ] \(taskText)"
        var lines = text.components(separatedBy: "\n")

        // Try to insert into "## Today" section
        if let todayIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Today"
        }) {
            var insertAt = todayIndex + 1
            for i in (todayIndex + 1)..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("## ") { break }
                insertAt = i + 1
            }
            // Back up past trailing blank lines
            while insertAt > todayIndex + 1
                && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty
            {
                insertAt -= 1
            }
            lines.insert(newTask, at: insertAt)
        } else {
            // No "## Today" — append to end
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(newTask)
            } else {
                lines = ["## Today", newTask]
            }
        }

        text = lines.joined(separator: "\n")
        scheduleSave()
    }

    // MARK: - Toolbar actions

    func openInDefaultEditor() {
        save()
        let path = currentFilePath
        if !FileManager.default.fileExists(atPath: path.path) {
            try? "".write(to: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(path)
    }

    func revealInFinder() {
        save()
        let path = currentFilePath
        if FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.activateFileViewerSelecting([path])
        } else {
            NSWorkspace.shared.open(storageDir)
        }
    }

    func copyContents() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Search

    func search(query: String) -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil)
        else { return [] }

        let lowered = query.lowercased()
        var results: [SearchResult] = []

        for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let name = file.deletingPathExtension().lastPathComponent
            guard let date = Self.fileFormatter.date(from: name) else { continue }
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }

            let matching = content.components(separatedBy: "\n")
                .filter { $0.lowercased().contains(lowered) }
                .map { $0.trimmingCharacters(in: .whitespaces) }

            if !matching.isEmpty {
                results.append(
                    SearchResult(
                        date: date,
                        dateString: name,
                        matchingLines: Array(matching.prefix(3))
                    ))
            }
        }

        return results
    }
}

struct SearchResult: Identifiable {
    let id = UUID()
    let date: Date
    let dateString: String
    let matchingLines: [String]
}

// MARK: - Main View

struct NoteView: View {
    @StateObject private var store = NoteStore()
    @State private var showingCalendar = false
    @State private var editingRaw = false
    @State private var showingNewNotebook = false
    @State private var newNotebookName = ""
    @State private var searchMode = false
    @State private var searchQuery = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: notebook picker + search + overflow menu
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.notebooks, id: \.self) { name in
                        Button(action: { store.switchNotebook(to: name) }) {
                            HStack {
                                Text(name)
                                if name == store.currentNotebook {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("New Notebook...") {
                        newNotebookName = ""
                        showingNewNotebook = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(store.currentNotebook)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()

                Button(action: { searchMode.toggle(); if !searchMode { searchQuery = "" } }) {
                    Image(systemName: searchMode ? "xmark" : "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(searchMode ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(searchMode ? "Close search" : "Search")

                // Overflow menu
                Menu {
                    Button(action: { store.openInDefaultEditor() }) {
                        Label("Open in Editor", systemImage: "arrow.up.forward.square")
                    }
                    Button(action: { store.revealInFinder() }) {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Button(action: { store.copyContents() }) {
                        Label("Copy Contents", systemImage: "doc.on.doc")
                    }

                    Toggle(isOn: $editingRaw) {
                        Label("Edit Markdown", systemImage: "pencil.line")
                    }

                    Divider()

                    Toggle("Launch at Login", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            LaunchAtLogin.toggle()
                            launchAtLogin = newValue
                        }
                    ))

                    Divider()

                    Button("Quit GSD") {
                        NSApp.terminate(nil)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if searchMode {
                SearchView(store: store, query: $searchQuery, searchMode: $searchMode)
            } else {
                // Date header
                HStack(spacing: 8) {
                    Button(action: { store.goToPreviousDay() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    Button(action: { showingCalendar.toggle() }) {
                        Text(formattedDate())
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.2), value: store.dateString)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingCalendar) {
                        CalendarPickerView(store: store, isPresented: $showingCalendar)
                    }

                    Button(action: { store.goToNextDay() }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if !store.isToday {
                        Button(action: { store.goToToday() }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Back to today")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                Divider()

                // Content area
                if editingRaw {
                    TextEditor(text: $store.text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .onChange(of: store.text) { _ in
                            store.scheduleSave()
                        }
                } else {
                    RichEditorView(store: store)
                }

                // Footer
                HStack {
                    Text("\(store.wordCount) words")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 3)
            }
        }
        .frame(width: 400, height: 500)
        .background(.ultraThinMaterial)
        .onAppear {
            store.refreshIfNeeded()
            store.scanExistingNotes()
        }
        .sheet(isPresented: $showingNewNotebook) {
            NewNotebookSheet(
                name: $newNotebookName,
                isPresented: $showingNewNotebook,
                onCreate: { name in
                    store.createNotebook(name: name)
                }
            )
        }
    }

    private func formattedDate() -> String {
        let cal = Calendar.current
        let date = store.currentDate

        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }

        let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day ?? 999
        if daysAgo > 0 && daysAgo < 7 {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: date)
        }

        let f = DateFormatter()
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "MMM d, yyyy"
        }
        return f.string(from: date)
    }
}

// MARK: - Search View

struct SearchView: View {
    @ObservedObject var store: NoteStore
    @Binding var query: String
    @Binding var searchMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("Search notes...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Results
            let results = store.search(query: query)

            if query.isEmpty {
                Spacer()
                Text("Type to search across all notes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else if results.isEmpty {
                Spacer()
                Text("No results")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { result in
                            Button(action: {
                                store.navigateTo(date: result.date)
                                searchMode = false
                                query = ""
                            }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(formatResultDate(result.date))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.primary)

                                    ForEach(result.matchingLines, id: \.self) { line in
                                        Text(line)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
    }

    private func formatResultDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - New Notebook Sheet

struct NewNotebookSheet: View {
    @Binding var name: String
    @Binding var isPresented: Bool
    var onCreate: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Notebook")
                .font(.headline)

            TextField("Notebook name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 280)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        isPresented = false
    }
}


// MARK: - Markdown Note Editor

/// Applies live markdown formatting to an NSTextStorage.
class MarkdownStyler: NSObject, NSTextStorageDelegate {

    static let baseFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    static let h1Font = NSFont.systemFont(ofSize: 24, weight: .bold)
    static let h2Font = NSFont.systemFont(ofSize: 18, weight: .bold)
    static let h3Font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static let markerColor = NSColor.tertiaryLabelColor
    static let checkedColor = NSColor.secondaryLabelColor

    static let boldPattern = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    static let italicPattern = try! NSRegularExpression(
        pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)")

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        applyMarkdown(to: textStorage)
    }

    func applyMarkdown(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let string = storage.string as NSString

        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = 5
        baseParagraph.paragraphSpacing = 2

        storage.addAttributes([
            .font: Self.baseFont,
            .foregroundColor: NSColor.labelColor,
            .strikethroughStyle: 0,
            .paragraphStyle: baseParagraph,
        ], range: full)

        // Process each line
        string.enumerateSubstrings(
            in: full, options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            self.styleLine(in: storage, range: lineRange)
        }

        // Inline formatting across full text
        applyInlineFormatting(to: storage)
    }

    private func styleLine(in storage: NSTextStorage, range: NSRange) {
        let string = storage.string as NSString
        let line = string.substring(with: range)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Headers
        if trimmed.hasPrefix("### ") {
            applyHeader(storage, range: range, line: line, prefix: "### ", font: Self.h3Font, spacingBefore: 6)
        } else if trimmed.hasPrefix("## ") {
            applyHeader(storage, range: range, line: line, prefix: "## ", font: Self.h2Font, spacingBefore: 10)
        } else if trimmed.hasPrefix("# ") {
            applyHeader(storage, range: range, line: line, prefix: "# ", font: Self.h1Font, spacingBefore: 12)
        }
        // Divider
        else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: range)
        }
        // Checked checkbox
        else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            let prefix = trimmed.hasPrefix("- [x] ") ? "- [x] " : "- [X] "
            if let pr = markerRange(in: line, prefix: prefix, baseLocation: range.location) {
                storage.addAttribute(.foregroundColor, value: Self.markerColor, range: pr)
            }
            let prefixLen = prefix.count
            let leadingSpaces = line.count - line.drop(while: { $0 == " " }).count
            let textStart = range.location + leadingSpaces + prefixLen
            let textLen = range.location + range.length - textStart
            if textLen > 0 {
                let textRange = NSRange(location: textStart, length: textLen)
                storage.addAttribute(.foregroundColor, value: Self.checkedColor, range: textRange)
                storage.addAttribute(
                    .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: textRange)
                storage.addAttribute(.strikethroughColor, value: Self.checkedColor, range: textRange)
            }
        }
        // Unchecked checkbox
        else if trimmed.hasPrefix("- [ ] ") {
            if let pr = markerRange(in: line, prefix: "- [ ] ", baseLocation: range.location) {
                storage.addAttribute(.foregroundColor, value: Self.markerColor, range: pr)
            }
        }
        // Bullet
        else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            if let pr = markerRange(
                in: line, prefix: String(trimmed.prefix(2)), baseLocation: range.location)
            {
                storage.addAttribute(.foregroundColor, value: Self.markerColor, range: pr)
            }
        }
    }

    private func applyHeader(
        _ storage: NSTextStorage, range: NSRange, line: String,
        prefix: String, font: NSFont, spacingBefore: CGFloat
    ) {
        storage.addAttribute(.font, value: font, range: range)
        if let pr = markerRange(in: line, prefix: prefix, baseLocation: range.location) {
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: pr)
            // Make the prefix smaller
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .regular), range: pr)
        }
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = spacingBefore
        para.lineSpacing = 4
        para.paragraphSpacing = 2
        storage.addAttribute(.paragraphStyle, value: para, range: range)
    }

    private func markerRange(in line: String, prefix: String, baseLocation: Int) -> NSRange? {
        let ns = line as NSString
        let r = ns.range(of: prefix)
        guard r.location != NSNotFound else { return nil }
        return NSRange(location: baseLocation + r.location, length: r.length)
    }

    private func applyInlineFormatting(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        let string = storage.string

        // Bold: **text**
        for match in Self.boldPattern.matches(in: string, range: full).reversed() {
            let matchRange = match.range
            let content = match.range(at: 1)
            guard content.location != NSNotFound else { continue }

            if let existing = storage.attribute(.font, at: content.location, effectiveRange: nil)
                as? NSFont
            {
                let bold = NSFontManager.shared.convert(existing, toHaveTrait: .boldFontMask)
                storage.addAttribute(.font, value: bold, range: content)
            }
            let openMarker = NSRange(location: matchRange.location, length: 2)
            let closeMarker = NSRange(
                location: matchRange.location + matchRange.length - 2, length: 2)
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: openMarker)
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: closeMarker)
        }

        // Italic: *text* (not adjacent to other *)
        for match in Self.italicPattern.matches(in: string, range: full).reversed() {
            let matchRange = match.range
            let content = match.range(at: 1)
            guard content.location != NSNotFound else { continue }

            if let existing = storage.attribute(.font, at: content.location, effectiveRange: nil)
                as? NSFont
            {
                let italic = NSFontManager.shared.convert(existing, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: italic, range: content)
            }
            let openMarker = NSRange(location: matchRange.location, length: 1)
            let closeMarker = NSRange(
                location: matchRange.location + matchRange.length - 1, length: 1)
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: openMarker)
            storage.addAttribute(.foregroundColor, value: Self.markerColor, range: closeMarker)
        }
    }
}

/// Custom NSTextView with checkbox clicks, Cmd+B/I, and Enter continuation.
class MarkdownNSTextView: NSTextView {
    var onCheckboxToggle: ((NSRange) -> Void)?

    // MARK: Checkbox click detection

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let string = self.string as NSString

        if index < string.length {
            let lineRange = string.lineRange(
                for: NSRange(location: min(index, string.length - 1), length: 0))
            let line = string.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("- [ ]") || trimmed.hasPrefix("- [x]")
                || trimmed.hasPrefix("- [X]")
            {
                let offsetInLine = index - lineRange.location
                if offsetInLine < 6 {
                    onCheckboxToggle?(lineRange)
                    return
                }
            }
        }

        super.mouseDown(with: event)
    }

    // MARK: Keyboard shortcuts (Cmd+C/V/X/Z/A/B/I)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
            let chars = event.charactersIgnoringModifiers
        else {
            return super.performKeyEquivalent(with: event)
        }

        // Standard editing shortcuts — must be handled explicitly because
        // SwiftUI's hosting layer can swallow them before NSTextView sees them.
        switch chars {
        case "c":
            copy(nil)
            return true
        case "x":
            cut(nil)
            return true
        case "v":
            pasteAsPlainText(nil)
            return true
        case "a":
            selectAll(nil)
            return true
        case "z":
            if event.modifierFlags.contains(.shift) {
                undoManager?.redo()
            } else {
                undoManager?.undo()
            }
            return true
        default:
            break
        }

        // Markdown formatting shortcuts
        let prefix: String
        let suffix: String

        switch chars {
        case "b": prefix = "**"; suffix = "**"
        case "i": prefix = "*"; suffix = "*"
        default: return super.performKeyEquivalent(with: event)
        }

        let range = selectedRange()
        let ns = self.string as NSString

        if range.length == 0 {
            let insert = prefix + suffix
            insertText(insert, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + prefix.count, length: 0))
        } else {
            let selected = ns.substring(with: range)
            let pLen = prefix.count
            let sLen = suffix.count

            // Toggle off if already wrapped
            if range.location >= pLen
                && (range.location + range.length + sLen) <= ns.length
            {
                let before = ns.substring(
                    with: NSRange(location: range.location - pLen, length: pLen))
                let after = ns.substring(
                    with: NSRange(location: range.location + range.length, length: sLen))
                if before == prefix && after == suffix {
                    let fullRange = NSRange(
                        location: range.location - pLen, length: range.length + pLen + sLen)
                    if shouldChangeText(in: fullRange, replacementString: selected) {
                        replaceCharacters(in: fullRange, with: selected)
                        didChangeText()
                    }
                    setSelectedRange(
                        NSRange(location: range.location - pLen, length: selected.count))
                    return true
                }
            }

            // Wrap selection
            let replacement = prefix + selected + suffix
            if shouldChangeText(in: range, replacementString: replacement) {
                replaceCharacters(in: range, with: replacement)
                didChangeText()
            }
            setSelectedRange(NSRange(location: range.location + pLen, length: selected.count))
        }

        return true
    }

    // MARK: Enter – continue checkboxes / bullets

    override func insertNewline(_ sender: Any?) {
        let ns = self.string as NSString
        let cursor = selectedRange().location
        guard cursor <= ns.length else {
            super.insertNewline(sender)
            return
        }

        let lineRange = ns.lineRange(for: NSRange(location: min(cursor, max(ns.length - 1, 0)), length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Checkbox continuation
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ")
            || trimmed.hasPrefix("- [X] ")
        {
            let taskText = trimmed.count > 6
                ? String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) : ""
            if taskText.isEmpty {
                let prefixRange = (line as NSString).range(of: trimmed)
                if prefixRange.location != NSNotFound {
                    let abs = NSRange(
                        location: lineRange.location + prefixRange.location,
                        length: prefixRange.length)
                    if shouldChangeText(in: abs, replacementString: "") {
                        replaceCharacters(in: abs, with: "")
                        didChangeText()
                    }
                }
                return
            }
            super.insertNewline(sender)
            insertText("- [ ] ", replacementRange: selectedRange())
            return
        }

        // Bullet continuation
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if content.isEmpty {
                let prefixRange = (line as NSString).range(of: trimmed)
                if prefixRange.location != NSNotFound {
                    let abs = NSRange(
                        location: lineRange.location + prefixRange.location,
                        length: prefixRange.length)
                    if shouldChangeText(in: abs, replacementString: "") {
                        replaceCharacters(in: abs, with: "")
                        didChangeText()
                    }
                }
                return
            }
            let bulletPrefix = String(trimmed.prefix(2))
            super.insertNewline(sender)
            insertText(bulletPrefix, replacementRange: selectedRange())
            return
        }

        super.insertNewline(sender)
    }
}

/// Sorts contiguous blocks of checkbox lines: unchecked first, checked last.
/// Preserves relative order within each group (stable partition).
/// Converts markdown checkbox syntax to visual circles for display.
///   `- [ ] task` → `○ task`    `- [x] task` → `● task`
private func displayText(from storage: String) -> String {
    storage.components(separatedBy: "\n").map { line in
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            return "● " + String(line.dropFirst(6))
        } else if line.hasPrefix("- [ ] ") {
            return "○ " + String(line.dropFirst(6))
        }
        return line
    }.joined(separator: "\n")
}

/// Converts visual circles back to markdown checkbox syntax for storage.
private func storageText(from display: String) -> String {
    display.components(separatedBy: "\n").map { line in
        if line.hasPrefix("● ") {
            return "- [x] " + String(line.dropFirst(2))
        } else if line.hasPrefix("○ ") {
            return "- [ ] " + String(line.dropFirst(2))
        }
        return line
    }.joined(separator: "\n")
}

private func sortCheckboxBlocks(in text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    var i = 0

    while i < lines.count {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- [ ]") || t.hasPrefix("- [x]") || t.hasPrefix("- [X]") {
            let blockStart = i
            while i < lines.count {
                let lt = lines[i].trimmingCharacters(in: .whitespaces)
                guard lt.hasPrefix("- [ ]") || lt.hasPrefix("- [x]") || lt.hasPrefix("- [X]")
                else { break }
                i += 1
            }

            let block = Array(lines[blockStart..<i])
            let unchecked = block.filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]")
            }
            let checked = block.filter {
                let s = $0.trimmingCharacters(in: .whitespaces)
                return s.hasPrefix("- [x]") || s.hasPrefix("- [X]")
            }
            let sorted = unchecked + checked

            for j in blockStart..<i {
                lines[j] = sorted[j - blockStart]
            }
        } else {
            i += 1
        }
    }

    return lines.joined(separator: "\n")
}

/// SwiftUI wrapper for the full markdown editor.
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = MarkdownNSTextView(frame: .zero, textContainer: textContainer)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)

        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = MarkdownStyler.baseFont
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]

        // Wire up styler & delegate
        let styler = context.coordinator.styler
        textStorage.delegate = styler
        textView.delegate = context.coordinator

        // Checkbox toggle
        textView.onCheckboxToggle = { lineRange in
            context.coordinator.toggleCheckbox(in: textView, lineRange: lineRange)
        }

        // Initial content
        context.coordinator.isSyncing = true
        textView.string = text
        styler.applyMarkdown(to: textView.textStorage!)
        context.coordinator.isSyncing = false

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownNSTextView else { return }
        if textView.string != text {
            context.coordinator.isSyncing = true
            let sel = textView.selectedRange()
            textView.string = text
            context.coordinator.styler.applyMarkdown(to: textView.textStorage!)
            let maxLoc = (textView.string as NSString).length
            textView.setSelectedRange(
                NSRange(
                    location: min(sel.location, maxLoc),
                    length: min(sel.length, maxLoc - min(sel.location, maxLoc))))
            context.coordinator.isSyncing = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        let styler = MarkdownStyler()
        weak var textView: MarkdownNSTextView?
        var isSyncing = false

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isSyncing, let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func toggleCheckbox(in textView: MarkdownNSTextView, lineRange: NSRange) {
            let string = textView.string as NSString
            let line = string.substring(with: lineRange)

            var newLine: String
            if line.contains("- [ ]") {
                newLine = line.replacingOccurrences(of: "- [ ]", with: "- [x]")
            } else {
                newLine = line.replacingOccurrences(of: "- [x]", with: "- [ ]")
                    .replacingOccurrences(of: "- [X]", with: "- [ ]")
            }

            // Build toggled text, then sort checkbox blocks
            var text = textView.string
            if let range = Range(lineRange, in: text) {
                text.replaceSubrange(range, with: newLine)
            }
            text = sortCheckboxBlocks(in: text)

            // Apply as single change
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            isSyncing = true
            if textView.shouldChangeText(in: fullRange, replacementString: text) {
                textView.replaceCharacters(in: fullRange, with: text)
                textView.didChangeText()
            }
            parent.text = textView.string
            isSyncing = false
        }
    }
}

// MARK: - Rich Editor

struct RichEditorView: View {
    @ObservedObject var store: NoteStore
    @State private var newTaskText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            MarkdownEditorView(
                text: Binding(
                    get: { store.text },
                    set: { newValue in
                        store.text = newValue
                        store.scheduleSave()
                    }
                ))

            Divider()

            // Quick-add task bar
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.accentColor)
                TextField("What needs to get done?", text: $newTaskText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit {
                        let trimmed = newTaskText.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        addTask(trimmed)
                        newTaskText = ""
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func addTask(_ taskText: String) {
        let lines = store.text.components(separatedBy: "\n")
        let newTask = "- [ ] \(taskText)"

        if let todayIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## Today"
        }) {
            var insertAt = todayIdx + 1
            for i in (todayIdx + 1)..<lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("## ") { break }
                insertAt = i + 1
            }
            while insertAt > todayIdx + 1
                && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty
            {
                insertAt -= 1
            }
            var newLines = lines
            newLines.insert(newTask, at: insertAt)
            store.text = newLines.joined(separator: "\n")
        } else if lines.allSatisfy({
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            store.text = "## Today\n\(newTask)"
        } else {
            store.text += "\n" + newTask
        }

        store.text = sortCheckboxBlocks(in: store.text)
        store.scheduleSave()
    }
}

// MARK: - Calendar Picker

struct CalendarPickerView: View {
    @ObservedObject var store: NoteStore
    @Binding var isPresented: Bool

    @State private var displayedMonth: Date = Date()

    private let calendar = Calendar.current
    private let daysOfWeek = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(action: { changeMonth(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)

                Spacer()

                Text(monthYearString())
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button(action: { changeMonth(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach(daysOfWeek, id: \.self) { day in
                    Text(day)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let days = daysInMonth()
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4
            ) {
                ForEach(days, id: \.self) { day in
                    if let day = day {
                        let dc = calendar.dateComponents([.year, .month, .day], from: day)
                        let isSelected = calendar.isDate(day, inSameDayAs: store.currentDate)
                        let isToday = calendar.isDateInToday(day)
                        let hasNote = store.hasNote(for: dc)

                        Button(action: {
                            store.navigateTo(date: day)
                            isPresented = false
                        }) {
                            VStack(spacing: 2) {
                                Text("\(calendar.component(.day, from: day))")
                                    .font(.system(size: 12, weight: isToday ? .bold : .regular))
                                    .foregroundColor(
                                        dayColor(isSelected: isSelected, isToday: isToday))

                                Circle()
                                    .fill(hasNote ? Color.accentColor : Color.clear)
                                    .frame(width: 4, height: 4)
                            }
                            .frame(width: 28, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(
                                        isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(width: 28, height: 32)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 240)
        .onAppear {
            displayedMonth = store.currentDate
        }
    }

    private func monthYearString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func changeMonth(by value: Int) {
        if let newMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) {
            displayedMonth = newMonth
        }
    }

    private func dayColor(isSelected: Bool, isToday: Bool) -> Color {
        if isSelected { return .accentColor }
        if isToday { return .primary }
        return .primary
    }

    private func daysInMonth() -> [Date?] {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let firstOfMonth = calendar.date(from: comps),
            let range = calendar.range(of: .day, in: .month, for: firstOfMonth)
        else {
            return []
        }

        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth) - 1

        var days: [Date?] = Array(repeating: nil, count: weekdayOfFirst)

        for day in range {
            var dc = comps
            dc.day = day
            if let date = calendar.date(from: dc) {
                days.append(date)
            }
        }

        return days
    }
}
