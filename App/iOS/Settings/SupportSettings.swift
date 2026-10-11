import HearthData
import HearthModel
import HearthUI
import OSLog
import SwiftUI

/// GitHub issues, log export (OSLogStore → share sheet) and diagnostics.
struct SupportSettingsView: View {
    @State private var exportedLog: URL?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                Link(destination: AppLinks.issues) {
                    Label("Report an Issue on GitHub", systemImage: "ladybug")
                }
                Link(destination: AppLinks.repository) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } footer: {
                Text("Please include exported logs when reporting a problem. Logs never contain passwords or tokens.")
            }

            Section("Logs") {
                if let exportedLog {
                    ShareLink(item: exportedLog) {
                        Label("Share Logs", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    Task { await exportLogs() }
                } label: {
                    HStack {
                        Label(exportedLog == nil ? String(localized: "Export Logs") : String(localized: "Export Again"), systemImage: "doc.text")
                        if isExporting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isExporting)
                if let exportError {
                    Text(exportError)
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            Section("Diagnostics") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Build", value: AppInfo.build)
                LabeledContent("System", value: AppInfo.system)
                LabeledContent("Device", value: AppInfo.model)
                LabeledContent("Servers", value: "\(HearthData.shared.connections.connections.count)")
                LabeledContent("Libraries", value: "\(HearthData.shared.connections.allLibraries.count)")
                LabeledContent("Offline Mode", value: HearthData.shared.connections.isOffline ? String(localized: "On") : String(localized: "Off"))
            }
        }
        .navigationTitle("Support")
    }

    private func exportLogs() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            exportedLog = try await LogExporter.export()
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// Collects this process's log entries of the last 24 h into a text file.
enum LogExporter {
    @MainActor
    static func export() async throws -> URL {
        let subsystem = Bundle.main.bundleIdentifier ?? "Hearth"
        let header = """
        Hearth \(AppInfo.version) (\(AppInfo.build))
        \(AppInfo.system) – \(AppInfo.model)
        Exported \(Date.now.formatted(.iso8601))

        """
        return try await Task.detached(priority: .userInitiated) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date.now.addingTimeInterval(-24 * 3600))
            let entries = try store.getEntries(at: position)
            var lines: [String] = [header]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                // Hearth's own subsystems plus errors from system frameworks.
                guard log.subsystem.hasPrefix(subsystem) || log.subsystem.hasPrefix("me.robinferch.hearth") || log.level == .error || log.level == .fault else { continue }
                lines.append("\(formatter.string(from: log.date)) [\(log.level.label)] \(log.category): \(log.composedMessage)")
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "Hearth-Log-\(Int(Date.now.timeIntervalSince1970)).txt")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }.value
    }
}

private extension OSLogEntryLog.Level {
    var label: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }
}

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    @MainActor
    static var system: String { "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }

    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Version, license, acknowledgements, privacy.
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    HearthAppIcon()
                        .frame(width: 84, height: 84)
                    Text(verbatim: "Hearth")
                        .hearthTitle(.title)
                    Text("Version \(AppInfo.version) (\(AppInfo.build))")
                        .foregroundStyle(.secondary)
                    Text("A free, open-source audiobookshelf client.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink {
                    LicenseView()
                } label: {
                    Label("License", systemImage: "doc.plaintext")
                }
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("Privacy", systemImage: "hand.raised")
                }
                NavigationLink {
                    AcknowledgementsView()
                } label: {
                    Label("Acknowledgements", systemImage: "heart")
                }
                Link(destination: AppLinks.repository) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }

            Section {
                Text("Hearth is not affiliated with audiobookshelf or Apple.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseView: View {
    var body: some View {
        ScrollView {
            Text(verbatim: Self.mit)
                .font(.footnote.monospaced())
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .navigationTitle("MIT License")
        .navigationBarTitleDisplayMode(.inline)
    }

    static let mit = """
    MIT License

    Copyright (c) Hearth contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}

private struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                Text("Hearth does not collect any data. There are no analytics, no tracking and no third-party services.")
                Text("Hearth only talks to the audiobookshelf servers you add. Your credentials are stored in the Keychain on your device.")
                Text("Listening statistics and progress are stored on your own server and on this device.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                Link(destination: AppLinks.audiobookshelf) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "audiobookshelf")
                            .foregroundStyle(.primary)
                        Text("The self-hosted audiobook and podcast server Hearth connects to.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Hearth is built entirely with Apple frameworks and has no third-party dependencies.")
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
