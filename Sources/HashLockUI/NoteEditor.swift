import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// A note or a wallet: title, fields, the wallet's seed, free text and
/// attached files, in one scrolling page. Edits are saved as they are made.
struct NoteEditor: View {
    @Bindable var model: AppModel
    let item: Item
    @State private var title = ""
    @State private var dropTargeted = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.draft?.wallet != nil {
                    WalletSection(model: model, wallet: walletBinding)
                }
                FieldsSection(model: model, fields: fieldsBinding)
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle("Notes")
                    PlainTextView(text: textBinding, placeholder: "Write anything here…")
                        .padding(10)
                        .contentCard()
                }
                AttachmentsSection(model: model, item: item)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            let id = item.id
            Task { await model.attach(await Imports.load(providers), to: id) }
            return true
        }
        .overlay {
            if dropTargeted {
                DropHighlight(text: "Attach to “\(item.title)”")
            }
        }
        .overlay(alignment: .bottom) { CopiedToast(clipboard: model.clipboard) }
        .onAppear {
            title = item.title
            if model.focusTitle {
                titleFocused = true
                model.focusTitle = false
            }
        }
        .onChange(of: item.id) { title = item.title }
        .onChange(of: model.focusTitle) { _, now in
            if now { titleFocused = true; model.focusTitle = false }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .bold))
                .focused($titleFocused)
                .onChange(of: title) { _, t in if t != item.title { model.titleEdited(item.id, t) } }
            Text("Modified \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }


    private var textBinding: Binding<String> {
        Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 })
    }

    private var fieldsBinding: Binding<[Field]> {
        Binding(get: { model.draft?.fields ?? [] }, set: { model.draft?.fields = $0 })
    }

    private var walletBinding: Binding<WalletBackup> {
        Binding(get: { model.draft?.wallet ?? WalletBackup() }, set: { model.draft?.wallet = $0 })
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct DropHighlight: View {
    let text: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 10))
            Label(text, systemImage: "paperclip")
                .font(.headline)
                .padding(10)
                .background(.regularMaterial, in: .capsule)
        }
        .padding(8)
        .allowsHitTesting(false)
    }
}

/// "Password copied" at the bottom of the window, for two seconds.
struct CopiedToast: View {
    let clipboard: Clipboard
    @State private var visible: String?

    var body: some View {
        Group {
            if let visible {
                Label(visible, systemImage: "doc.on.clipboard")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 16)
        .animation(.easeOut(duration: 0.2), value: visible)
        .task(id: clipboard.copyCount) {
            guard let label = clipboard.lastCopiedLabel, clipboard.copyCount > 0 else { return }
            let seconds = Preferences.defaults.integer(forKey: Preferences.clipboardClearKey)
            visible = seconds > 0 ? "\(label) copied · clears in \(Preferences.seconds(seconds))" : "\(label) copied"
            try? await Task.sleep(for: .seconds(2.2))
            visible = nil
        }
    }
}

// MARK: Fields

struct FieldsSection: View {
    let model: AppModel
    @Binding var fields: [Field]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Fields")
                Spacer()
                Menu {
                    ForEach(Field.Kind.allCases) { kind in
                        Button { fields.append(Field(kind: kind)) } label: {
                            Label(kind.defaultLabel, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Add Field", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a login, password, IP address, website or other value")
            }
            if !fields.isEmpty {
                VStack(spacing: 0) {
                    ForEach($fields) { $field in
                        FieldRow(model: model, field: $field, onRemove: {
                            fields.removeAll { $0.id == field.id }
                        }, onMove: { delta in
                            move(field.id, by: delta)
                        })
                        if field.id != fields.last?.id { Divider().padding(.leading, 12) }
                    }
                }
                .contentCard()
            }
        }
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let i = fields.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard fields.indices.contains(j) else { return }
        fields.swapAt(i, j)
    }
}

/// One field: the label and the value; dots say when the value is hidden.
/// The row's buttons — show/hide, copy, and the menu (generate, kind, hide
/// by default, move, remove) — appear together, the same on every field,
/// while the pointer is over the row or its value is being edited. Their
/// place is kept, so nothing moves.
struct FieldRow: View {
    let model: AppModel
    @Binding var field: Field
    let onRemove: () -> Void
    let onMove: (Int) -> Void
    /// Shown or hidden for now by the eye; `nil` follows the default.
    @State private var override: Bool?
    @State private var hovering = false
    @State private var showGenerator = false
    @FocusState private var editing: Bool
    @State private var editingShown = false
    private var showControls: Bool { hovering || editing || editingShown || showGenerator }

    /// The field's own choice, or for passwords and secrets the one in
    /// Settings › Privacy.
    private var hiddenByDefault: Bool {
        field.concealed ?? (field.kind.isSecret && Preferences.defaults.bool(forKey: Preferences.concealSecretsKey))
    }

    private var hidden: Bool { override ?? hiddenByDefault }

    var body: some View {
        // Aligned on the first line: a long value wraps below it.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: field.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("Label", text: $field.label)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 110)
            value
                .popover(isPresented: $showGenerator, arrowEdge: .bottom) {
                    if field.kind == .login {
                        LoginGeneratorPopover { field.value = $0 }
                    } else {
                        GeneratorPopover { field.value = $0 }
                    }
                }
            if field.kind == .address, !field.value.isEmpty, !AddressCheck.isValid(field.value) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Not an IP address or host name (an optional :port may follow)")
            }
            controls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var value: some View {
        if hidden {
            SecureField("Value", text: $field.value)
                .focused($editing)
                .textFieldStyle(.plain)
                .textContentType(.none)
        } else {
            ValueField(text: $field.value, placeholder: "Value",
                       code: field.kind.isSecret || field.kind == .address,
                       onEditing: { editingShown = $0 })
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { override = !hidden } label: {
                Image(systemName: hidden ? "eye" : "eye.slash")
            }
            .help(hidden ? "Show" : "Hide")
            .accessibilityLabel(hidden ? "Show \(field.label)" : "Hide \(field.label)")
            .opacity(showControls ? 1 : 0)

            CopyButton(help: "Copy \(field.label)", visible: showControls) {
                model.clipboard.copy(field.value, label: field.label, secret: field.kind.isSecret || hiddenByDefault)
            }
            .disabled(field.value.isEmpty)

            Menu {
                if field.kind == .password || field.kind == .secret {
                    Button("Generate Password…") { showGenerator = true }
                } else if field.kind == .login {
                    Button("Generate Login…") { showGenerator = true }
                }
                Toggle("Hide by Default", isOn: Binding(
                    get: { hiddenByDefault },
                    set: { field.concealed = $0; override = nil }))
                Picker("Kind", selection: $field.kind) {
                    ForEach(Field.Kind.allCases) { Label($0.defaultLabel, systemImage: $0.symbol).tag($0) }
                }
                Divider()
                Button("Move Up") { onMove(-1) }
                Button("Move Down") { onMove(1) }
                Divider()
                Button("Remove Field", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
            .opacity(showControls ? 1 : 0)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

/// Generates a user name into a Login field.
struct LoginGeneratorPopover: View {
    let use: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var style = LoginGenerator.Style.words
    @State private var candidate = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(candidate)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(width: 260, alignment: .leading)
                .padding(8)
                .contentCard(cornerRadius: 6)
            Picker("", selection: $style) {
                Text("Words").tag(LoginGenerator.Style.words)
                Text("Random").tag(LoginGenerator.Style.random)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Button { candidate = LoginGenerator.generate(style) } label: { Label("New", systemImage: "arrow.clockwise") }
                Spacer()
                Button("Use Login") {
                    use(candidate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { candidate = LoginGenerator.generate(style) }
        .onChange(of: style) { candidate = LoginGenerator.generate(style) }
    }
}

/// Generates a password into a field.
struct GeneratorPopover: View {
    let use: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = GeneratorPopover.saved
    @State private var candidate = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(candidate)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(width: 300, alignment: .leading)
                .padding(8)
                .contentCard(cornerRadius: 6)
            Picker("", selection: $options.style) {
                Text("Characters").tag(PasswordGenerator.Options.Style.characters)
                Text("Words").tag(PasswordGenerator.Options.Style.words)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if options.style == .characters {
                Stepper("Length: \(options.length)", value: $options.length, in: 8...64)
                Toggle("Digits", isOn: $options.digits)
                Toggle("Symbols", isOn: $options.symbols)
                Toggle("Avoid look-alike characters", isOn: $options.avoidAmbiguous)
            } else {
                Stepper("Words: \(options.wordCount)", value: $options.wordCount, in: 3...12)
            }
            Text("\(Int(PasswordGenerator.entropyBits(options))) bits of entropy")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button { regenerate() } label: { Label("New", systemImage: "arrow.clockwise") }
                Spacer()
                Button("Use Password") {
                    use(candidate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear(perform: regenerate)
        .onChange(of: options) {
            regenerate()
            GeneratorPopover.saved = options
        }
    }

    private func regenerate() { candidate = PasswordGenerator.generate(options) }

    /// The last options used, remembered across launches (they are not secret).
    static var saved: PasswordGenerator.Options {
        get {
            (Preferences.defaults.data(forKey: "generatorOptions"))
                .flatMap { try? JSONDecoder().decode(PasswordGenerator.Options.self, from: $0) } ?? .init()
        }
        set { Preferences.defaults.set(try? JSONEncoder().encode(newValue), forKey: "generatorOptions") }
    }
}

/// Whether a value looks like an IPv4 or IPv6 address or a host name, with
/// an optional port: 10.0.0.1, 10.0.0.1:22, [2001:db8::1]:443, host.example.
enum AddressCheck {
    static func isValid(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return false }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            guard isIPv6(host) else { return false }
            return rest.isEmpty || (rest.hasPrefix(":") && isPort(String(rest.dropFirst())))
        }
        if isIPv6(s) { return true }
        if let colon = s.lastIndex(of: ":") {
            guard isPort(String(s[s.index(after: colon)...])) else { return false }
            s = String(s[..<colon])
        }
        return isIPv4(s) || isHostName(s)
    }

    static func isIPv4(_ s: String) -> Bool {
        var a = in_addr()
        return inet_pton(AF_INET, s, &a) == 1
    }

    static func isIPv6(_ s: String) -> Bool {
        var a = in6_addr()
        return inet_pton(AF_INET6, s, &a) == 1
    }

    static func isPort(_ s: String) -> Bool {
        guard let n = Int(s) else { return false }
        return (1...65535).contains(n)
    }

    static func isHostName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        return s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
