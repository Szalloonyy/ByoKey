//
//  SettingsView.swift
//  RecallDrop
//
//  Settings hub (iOS tab, macOS sidebar) and the sections it links to.
//  On macOS the same sections also appear in the Settings window.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import RecallDropKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let settings = environment.settings
        Form {
            Section {
                NavigationLink {
                    AISettingsView()
                } label: {
                    SettingsRow(title: "AI Provider", subtitle: settings.offlineOnly
                                ? "Offline Only"
                                : "\(settings.provider.displayName) · \(settings.activeDefaultModel)",
                                systemImage: "cpu", color: .indigo)
                }
                NavigationLink {
                    CaptureSettingsView()
                } label: {
                    SettingsRow(title: "Capture & Analysis",
                                subtitle: settings.autoAnalyze ? "Analyze new captures automatically" : "Manual analysis",
                                systemImage: "sparkles", color: .purple)
                }
                NavigationLink {
                    ReminderSettingsView()
                } label: {
                    SettingsRow(title: "Reminders", subtitle: "Times for Tonight, Tomorrow and more",
                                systemImage: "bell.badge", color: .orange)
                }
            }
            Section {
                NavigationLink {
                    DataSettingsView()
                } label: {
                    SettingsRow(title: "Data & Privacy", subtitle: "Export, clean up, erase", systemImage: "externaldrive", color: .gray)
                }
                NavigationLink {
                    AboutView()
                } label: {
                    SettingsRow(title: "About RecallDrop", subtitle: AppInfo.versionString, systemImage: "info.circle", color: .blue)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

struct SettingsRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Capture & analysis

struct CaptureSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    var body: some View {
        @Bindable var settings = environment.settings
        Form {
            Section {
                Toggle("Analyze New Captures Automatically", isOn: $settings.autoAnalyze)
                Picker("Default Agent", selection: defaultAgentBinding) {
                    ForEach(agents) { agent in
                        Text("\(agent.emoji) \(agent.displayName)").tag(Optional(agent.id))
                    }
                }
                Toggle("Load Link Previews", isOn: $settings.fetchLinkPreviews)
            } header: {
                Text("Analysis")
            } footer: {
                Text("Without an API key (or with Offline Only), new captures get an on-device analysis instead of the default agent.")
            }

            Section {
                Picker("Accuracy", selection: $settings.ocrAccuracy) {
                    ForEach(OCRAccuracy.allCases) { accuracy in
                        Text(accuracy.label).tag(accuracy)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Language Correction", isOn: $settings.ocrLanguageCorrection)
            } header: {
                Text("Text Recognition")
            } footer: {
                Text("Text is recognized on this device with Apple's Vision framework. “Accurate” is slower but handles small and stylized text better.")
            }

            Section("Appearance") {
                Picker("Card Size", selection: $settings.gridDensity) {
                    ForEach(GridDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Capture & Analysis")
    }

    private var defaultAgentBinding: Binding<UUID?> {
        Binding(
            get: { (agents.first(where: \.isDefault) ?? agents.first)?.id },
            set: { newID in
                if let agent = agents.first(where: { $0.id == newID }) {
                    environment.agents.setDefault(agent)
                }
            }
        )
    }
}

// MARK: - Reminders

struct ReminderSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var settings = environment.settings
        let reminders = environment.reminders
        Form {
            Section {
                LabeledContent("Notifications", value: reminders.isAuthorized ? "Allowed" : (reminders.isDenied ? "Off" : "Not Asked"))
                if !reminders.hasAskedForAuthorization {
                    Button("Allow Notifications") {
                        Task { await reminders.requestAuthorization() }
                    }
                } else if reminders.isDenied, let url = AppInfo.notificationSettingsURL {
                    Button("Open System Settings") { openURL(url) }
                }
            } footer: {
                Text("Reminders resurface a capture with its thumbnail. Snooze or archive right from the notification.")
            }

            Section {
                hourPicker("Tomorrow & Next Week", selection: $settings.morningHour)
                hourPicker("Tonight", selection: $settings.eveningHour)
                hourPicker("This Weekend", selection: $settings.weekendHour)
            } header: {
                Text("Quick Reminder Times")
            }

            Section("Preview") {
                let now = Date()
                ForEach(ReminderPreset.allCases) { preset in
                    LabeledContent(preset.title,
                                   value: preset.date(relativeTo: now, schedule: settings.reminderSchedule)
                                    .formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Reminders")
        .task { await reminders.refreshAuthorizationStatus() }
    }

    private func hourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<24, id: \.self) { hour in
                Text(Self.hourLabel(hour)).tag(hour)
            }
        }
    }

    static func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Data

struct DataSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Query private var items: [CapturedItem]

    @State private var exportDocument: JSONFileDocument?
    @State private var isExporterPresented = false
    @State private var isDeleteArchivedPresented = false
    @State private var isEraseConfirmationPresented = false
    @State private var message: String?

    private var storageDescription: String {
        if case .inMemoryFallback = environment.persistenceIssue {
            return "Temporary – captures are not saved"
        }
        return AppGroup.containerURL == nil ? "This app only" : "Shared with the Share Extension"
    }

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Captures", value: "\(items.count)")
                LabeledContent("Archived", value: "\(items.filter(\.isArchived).count)")
                LabeledContent("Storage", value: storageDescription)
            }

            Section {
                Button {
                    prepareExport()
                } label: {
                    Label("Export Library as JSON…", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Exports titles, text, notes, tags, agent results and your agents. Images stay on this device.")
            }

            Section {
                Button(role: .destructive) {
                    isDeleteArchivedPresented = true
                } label: {
                    Label("Delete Archived Captures", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    isEraseConfirmationPresented = true
                } label: {
                    Label("Erase All Data", systemImage: "trash")
                }
            } footer: {
                Text("API keys are removed from the Keychain when you erase all data.")
            }

            if let message {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Data & Privacy")
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .json,
            defaultFilename: LibraryExportDocument.suggestedFileName()
        ) { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .confirmationDialog("Delete all archived captures?", isPresented: $isDeleteArchivedPresented, titleVisibility: .visible) {
            Button("Delete Archived", role: .destructive) {
                LibraryMaintenance.deleteArchived(environment: environment)
                message = "Archived captures were deleted."
            }
        }
        .confirmationDialog("Erase everything?", isPresented: $isEraseConfirmationPresented, titleVisibility: .visible) {
            Button("Erase All Data", role: .destructive) {
                LibraryMaintenance.eraseEverything(environment: environment)
                message = "All captures, custom agents, keys and preferences were erased."
            }
        } message: {
            Text("This deletes every capture, custom agent, API key and preference on this device. It cannot be undone.")
        }
    }

    private func prepareExport() {
        let document = LibraryMaintenance.exportDocument(context: environment.container.mainContext)
        do {
            exportDocument = JSONFileDocument(data: try document.encoded())
            isExporterPresented = true
        } catch {
            message = error.localizedDescription
        }
    }
}

struct JSONFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RecallDrop")
                            .font(.title2.weight(.bold))
                        Text(AppInfo.versionString)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Text("A visual second brain for screenshots, links and fleeting ideas – searchable, organized and analyzed by specialized agents.")
                    .font(.callout)
            }

            Section("Privacy") {
                Label("Text recognition runs on this device.", systemImage: "text.viewfinder")
                Label("You bring your own API key; captures go only to the provider you choose.", systemImage: "key")
                Label("Offline Only keeps every capture on this device.", systemImage: "lock.shield")
                Label("No accounts, no tracking, no RecallDrop servers.", systemImage: "hand.raised")
            }

            Section("Credits") {
                Link("Agent personas inspired by msitarzewski/agency-agents", destination: URL(string: "https://github.com/msitarzewski/agency-agents")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}

enum AppInfo {
    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    static var notificationSettingsURL: URL? {
        #if os(iOS)
        URL(string: "app-settings:")
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        #endif
    }
}
