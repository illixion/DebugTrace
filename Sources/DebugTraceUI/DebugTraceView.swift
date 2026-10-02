import DebugTrace
import SwiftUI

/// Capture a trace, review what is in it, then share or upload it.
///
/// Review comes before sharing on purpose: the list shows every file and its
/// size, so the person sending it sees what leaves the device. That matters
/// most for apps like RegentChat, whose logs sit next to private messages.
public struct DebugTraceView: View {
    private enum Phase {
        case idle
        case capturing
        case captured(DebugTraceArchive)
        case failed(String)
    }

    private enum UploadState {
        case none
        case uploading
        case done(DebugTraceUploadResult)
        case failed(String)
    }

    private let surface: DebugSurface
    @State private var note = ""
    @State private var phase: Phase = .idle
    @State private var upload: UploadState = .none

    public init(surface: DebugSurface = .shared) {
        self.surface = surface
    }

    public var body: some View {
        Form {
            Section {
                TextField("What were you doing when it went wrong?", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Note")
            } footer: {
                if DebugTrace.privacy == .release {
                    Text("A report for the developer: this app's recent activity log, the features you used, and device details such as model and OS version. Personal details the app handles are left out. You can read every file before sending.")
                } else {
                    Text("Includes recent logs, feature history, app state and device info. Values logged as private are withheld and values that look like secrets are redacted.")
                }
            }

            Section {
                Button {
                    Task { await capture() }
                } label: {
                    if case .capturing = phase {
                        HStack {
                            ProgressView()
                            Text("Capturing…")
                        }
                    } else {
                        Label(isCaptured ? "Capture Again" : "Capture Trace", systemImage: "ladybug")
                    }
                }
                .disabled(isCapturing)
            }

            switch phase {
            case .captured(let archive):
                contents(archive)
                actions(archive)
            case .failed(let message):
                Section { Text(message).foregroundStyle(.red) }
            case .idle, .capturing:
                EmptyView()
            }
        }
        .navigationTitle("Debug Trace")
    }

    @ViewBuilder
    private func contents(_ archive: DebugTraceArchive) -> some View {
        Section {
            ForEach(archive.manifest.files, id: \.path) { file in
                if let text = archive.textFiles[file.path] {
                    NavigationLink {
                        DebugTraceFilePreview(path: file.path, text: text)
                    } label: {
                        LabeledContent(file.path, value: Self.size(file.bytes))
                    }
                } else {
                    LabeledContent(file.path, value: Self.size(file.bytes))
                }
            }
            LabeledContent("Total", value: Self.size(archive.bytes))
            LabeledContent("Signed", value: archive.manifest.signature?.keyId ?? "No — not a store build")
        } header: {
            Text("Contents")
        } footer: {
            Text("Tap a file to read it.")
        }
    }

    @ViewBuilder
    private func actions(_ archive: DebugTraceArchive) -> some View {
        Section {
            #if !os(tvOS)
            ShareLink(item: archive.url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            #endif
            if DebugTrace.canUpload {
                Button {
                    Task { await send(archive) }
                } label: {
                    Label(DebugTrace.privacy == .release ? "Send to Developer" : "Upload to App Store Server",
                          systemImage: "icloud.and.arrow.up")
                }
                .disabled(isUploading)
                uploadStatus
            }
        } footer: {
            #if os(tvOS)
            if !DebugTrace.canUpload {
                Text("This build has no upload destination, and tvOS has no share sheet. Fetch it over the debug server instead: /_traces/\(archive.id).zip")
            }
            #endif
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        switch upload {
        case .none:
            EmptyView()
        case .uploading:
            HStack {
                ProgressView()
                Text("Uploading…")
            }
        case .done(let result):
            if result.accepted {
                Label("Uploaded", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                Text("Server refused it (HTTP \(result.statusCode))\(Self.reason(result).map { ": \($0)" } ?? "")")
                    .foregroundStyle(.red)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private var isCapturing: Bool {
        if case .capturing = phase { return true }
        return false
    }

    private var isCaptured: Bool {
        if case .captured = phase { return true }
        return false
    }

    private var isUploading: Bool {
        if case .uploading = upload { return true }
        return false
    }

    private func capture() async {
        phase = .capturing
        upload = .none
        do {
            phase = .captured(try await DebugTrace.capture(note: note, surface: surface))
        } catch {
            phase = .failed("Capture failed: \(error)")
        }
    }

    private func send(_ archive: DebugTraceArchive) async {
        upload = .uploading
        do {
            upload = .done(try await DebugTrace.upload(archive))
        } catch {
            upload = .failed("Upload failed: \(error.localizedDescription)")
        }
    }

    /// The store answers `{"error": "why"}`; DebugTrace's own server
    /// `{"error": {"message": "why"}}`.
    private static func reason(_ result: DebugTraceUploadResult) -> String? {
        let error = result.response?["error"]
        return error?.stringValue ?? error?["message"]?.stringValue
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// A button that opens `DebugTraceView` in a sheet — for a Settings
/// developer section or a console toolbar.
public struct DebugTraceButton: View {
    private let surface: DebugSurface
    private let title: String
    @State private var presented = false

    public init(_ title: String = "Debug Trace…", surface: DebugSurface = .shared) {
        self.title = title
        self.surface = surface
    }

    public var body: some View {
        Button {
            presented = true
        } label: {
            Label(title, systemImage: "ladybug")
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                DebugTraceView(surface: surface)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { presented = false }
                        }
                    }
            }
        }
    }
}

/// One file of a trace, read-only. Long files show their end, where the
/// newest log lines are.
struct DebugTraceFilePreview: View {
    let path: String
    let text: String

    private static let limit = 200_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if text.utf8.count > Self.limit {
                    Text("Showing the last \(Self.limit / 1000) KB of \(text.utf8.count / 1000) KB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(shown)
                    .font(.system(.caption, design: .monospaced))
                    #if !os(tvOS)
                    .textSelection(.enabled)
                    #endif
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(path)
    }

    private var shown: String {
        guard text.utf8.count > Self.limit else { return text }
        return String(decoding: text.utf8.suffix(Self.limit), as: UTF8.self)
    }
}
