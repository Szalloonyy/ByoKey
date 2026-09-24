//
//  DetailSections.swift
//  RecallDrop
//
//  The building blocks of the detail view.
//

import SwiftUI
import SwiftData
import RecallDropKit

// MARK: - Hero

struct DetailHeroView: View {
    let item: CapturedItem
    let onOpenImage: () -> Void

    var body: some View {
        if item.hasImage {
            Button(action: onOpenImage) {
                CaptureImageView(cacheKey: item.fullImageCacheKey, data: item.imageData, maxPixelSize: 2400, contentMode: .fit)
                    .aspectRatio(CGFloat(item.imageWidth / max(item.imageHeight, 1)), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 560)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open image full screen")
        } else if item.kind == .link, let url = item.sourceURL {
            Link(destination: url) {
                HStack(spacing: 12) {
                    Image(systemName: "safari")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.linkTitle ?? url.host ?? url.absoluteString)
                            .font(.headline)
                            .lineLimit(2)
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .foregroundStyle(.secondary)
                }
                .panelStyle()
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Title & metadata

struct DetailTitleSection: View {
    @Bindable var item: CapturedItem

    /// Edited locally and stored on Return, when focus leaves or the view goes
    /// away; an emptied title goes back to automatic naming.
    @State private var titleDraft = ""
    @FocusState private var isEditingTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $titleDraft, prompt: Text(item.displayTitle), axis: .vertical)
                .font(.title2.weight(.bold))
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isEditingTitle)
                .onSubmit(commitTitle)
                .onChange(of: titleDraft) { _, newValue in
                    // Return adds a line break in a multi-line field on iOS; treat it as Done.
                    if newValue.contains("\n") {
                        titleDraft = newValue.replacingOccurrences(of: "\n", with: " ")
                        isEditingTitle = false
                    }
                }
                .onChange(of: isEditingTitle) { _, editing in
                    if !editing { commitTitle() }
                }
                .onChange(of: item.title) { _, newTitle in
                    if !isEditingTitle { titleDraft = newTitle }
                }
                .onAppear { titleDraft = item.title }
                .onDisappear(perform: commitTitle)

            HStack(spacing: 10) {
                Label(item.kind.label, systemImage: item.kind.symbolName)
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let app = item.sourceAppName {
                    Text("from \(app)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let url = item.sourceURL, item.kind != .link {
                Link(destination: url) {
                    Label(url.host ?? url.absoluteString, systemImage: "link")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    private func commitTitle() {
        guard !item.isDeleted, item.modelContext != nil else { return }
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != item.title else { return }
        item.title = title
        // With an empty title, agents may name the capture again.
        item.isTitleUserEdited = !title.isEmpty
        item.touch()
    }
}

// MARK: - Reminder

struct ReminderPanel: View {
    let item: CapturedItem

    @Environment(AppEnvironment.self) private var environment
    @State private var isCustomPickerPresented = false
    @State private var customDate = Date().addingTimeInterval(3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Remind Me", systemImage: "bell")

            if let date = item.reminderDate {
                HStack(spacing: 10) {
                    Image(systemName: date <= Date() ? "bell.badge.fill" : "bell.fill")
                        .foregroundStyle(date <= Date() ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(date.formatted(date: .complete, time: .shortened))
                            .font(.callout.weight(.medium))
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("Change") {
                        ReminderMenuContent(schedule: environment.settings.reminderSchedule, hasReminder: false,
                                            onSelect: schedule(at:), onClear: {})
                        Button("Custom…") { isCustomPickerPresented = true }
                    }
                    .fixedSize()
                    Button(role: .destructive) {
                        environment.reminders.cancelReminder(for: item)
                    } label: {
                        Image(systemName: "bell.slash")
                    }
                    .accessibilityLabel("Remove reminder")
                }
            } else {
                ReminderPresetGrid(schedule: environment.settings.reminderSchedule, onSelect: schedule(at:))
                Button {
                    isCustomPickerPresented = true
                } label: {
                    Label("Pick a Date & Time…", systemImage: "calendar.badge.clock")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            if let suggested = item.suggestedReminderDate, suggested > Date(), suggested != item.reminderDate {
                HStack {
                    Label("Suggested by \(item.lastUsedAgentName ?? "agent"): \(suggested.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use") { schedule(at: suggested) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let error = environment.reminders.lastError, environment.reminders.isDenied {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .panelStyle()
        .sheet(isPresented: $isCustomPickerPresented) {
            CustomReminderSheet(date: $customDate) { date in
                schedule(at: date)
            }
        }
    }

    private func schedule(at date: Date) {
        Task { await environment.reminders.schedule(item, at: date) }
    }
}

private struct CustomReminderSheet: View {
    @Binding var date: Date
    let onSave: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Remind me on", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("Custom Reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Reminder") {
                        onSave(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 440)
        #endif
    }
}

// MARK: - Extracted text

struct ExtractedTextPanel: View {
    @Bindable var item: CapturedItem

    @Environment(AppEnvironment.self) private var environment
    @State private var isExpanded = false

    private let collapsedLength = 700

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(title, systemImage: item.kind == .note ? "note.text" : "text.viewfinder",
                        trailing: AnyView(trailingButtons))

            if item.kind == .note {
                TextEditor(text: noteBinding)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
            } else if let text = item.extractedText?.trimmedNonEmpty {
                Text(isExpanded || text.count <= collapsedLength ? text : String(text.prefix(collapsedLength)) + "…")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if text.count > collapsedLength {
                    Button(isExpanded ? "Show Less" : "Show All") {
                        withAnimation { isExpanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
                if let confidence = item.ocrConfidence {
                    Text("Recognized on this device · \(Int((confidence * 100).rounded())) % confidence")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No text was found in this image.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .panelStyle()
    }

    private var title: String {
        switch item.kind {
        case .note: "Note"
        case .link: "Page Text"
        case .screenshot, .photo: "Extracted Text"
        }
    }

    private var trailingButtons: some View {
        HStack(spacing: 12) {
            if let text = item.extractedText?.trimmedNonEmpty {
                Button {
                    Clipboard.copy(text)
                    environment.router.showToast("Text copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy text")
            }
            if item.hasImage {
                Button {
                    environment.pipeline.rerunTextRecognition(on: item)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Read text again")
                .disabled(environment.pipeline.isBusy(item.id))
            }
        }
        .buttonStyle(.borderless)
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { item.extractedText ?? "" },
            set: { newValue in
                item.extractedText = newValue
                item.touch()
            }
        )
    }
}

// MARK: - Notes

struct NotesPanel: View {
    @Bindable var item: CapturedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader("My Notes", systemImage: "pencil.line")
            TextEditor(text: notesBinding)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if (item.userNotes ?? "").isEmpty {
                        Text("Why did you save this? Add context for yourself and your agents.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
        }
        .panelStyle()
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { item.userNotes ?? "" },
            set: { newValue in
                item.userNotes = newValue.isEmpty ? nil : newValue
                item.touch()
            }
        )
    }
}

// MARK: - Tags

struct TagEditorPanel: View {
    @Bindable var item: CapturedItem

    @Query private var allItems: [CapturedItem]
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader("Tags", systemImage: "number")

            if item.tags.isEmpty {
                Text("No tags yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout {
                    ForEach(item.tags, id: \.self) { tag in
                        TagChip(tag: tag) {
                            item.setTags(item.tags.filter { $0 != tag })
                        }
                    }
                }
            }

            HStack {
                TextField("Add tag", text: $newTag)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Button("Add", action: addTag)
                    .disabled(TagNormalizer.normalize(newTag) == nil)
            }

            let suggestions = suggestedTags
            if !suggestions.isEmpty {
                FlowLayout {
                    ForEach(suggestions, id: \.self) { tag in
                        Button {
                            item.setTags(item.tags + [tag])
                            newTag = ""
                        } label: {
                            TagChip(tag: tag)
                                .opacity(0.75)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .panelStyle()
    }

    private func addTag() {
        guard let tag = TagNormalizer.normalize(newTag) else { return }
        item.setTags(item.tags + [tag])
        newTag = ""
    }

    /// Existing tags from the library that match what is being typed,
    /// or the most used ones when the field is empty.
    private var suggestedTags: [String] {
        var counts: [String: Int] = [:]
        for other in allItems {
            for tag in other.tags { counts[tag, default: 0] += 1 }
        }
        let prefix = TagNormalizer.normalize(newTag) ?? ""
        return counts
            .filter { !item.tags.contains($0.key) && (prefix.isEmpty || $0.key.hasPrefix(prefix)) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8)
            .map(\.key)
    }
}
