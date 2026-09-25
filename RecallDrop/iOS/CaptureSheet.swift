//
//  CaptureSheet.swift
//  RecallDrop (iOS)
//
//  The sheet behind the floating "+" button: paste from the clipboard,
//  pick from the photo library, take a photo, scan a document, save a link
//  or jot a note – and choose which agent analyzes it.
//

import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit
import RecallDropKit

struct CaptureSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var choice: AgentChoice = .none
    @State private var reminder: ReminderPreset?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isCameraPresented = false
    @State private var isScannerPresented = false
    @State private var linkText = ""
    @State private var noteText = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PasteButton(supportedContentTypes: [.image, .url, .plainText]) { providers in
                        Task { await capture(providers: providers) }
                    }
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    PhotosPicker(selection: $photoSelection, maxSelectionCount: 12, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle.angled")
                    }

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            isCameraPresented = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                    }

                    if VNDocumentCameraViewController.isSupported {
                        Button {
                            isScannerPresented = true
                        } label: {
                            Label("Scan Document", systemImage: "doc.viewfinder")
                        }
                    }
                } header: {
                    Text("Capture")
                }

                Section("Save a Link") {
                    HStack {
                        TextField("https://…", text: $linkText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await saveLink() } }
                        Button("Save") { Task { await saveLink() } }
                            .disabled(validLink == nil)
                    }
                }

                Section("Quick Note") {
                    TextField("A fleeting idea…", text: $noteText, axis: .vertical)
                        .lineLimit(2...6)
                    Button("Save Note") { Task { await saveNote() } }
                        .disabled(noteText.trimmedNonEmpty == nil)
                }

                Section {
                    AgentChoiceChips(agents: agents, selection: $choice)
                    Picker("Remind Me", selection: $reminder) {
                        Text("No Reminder").tag(ReminderPreset?.none)
                        ForEach(ReminderPreset.allCases) { preset in
                            Text(preset.title).tag(ReminderPreset?.some(preset))
                        }
                    }
                } header: {
                    Text("Then")
                } footer: {
                    if let reason = environment.settings.aiUnavailableReason, case .agent = choice {
                        Text("\(reason) The capture gets the on-device analysis now; the agent runs once AI is available.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if isWorking {
                    ToolbarItem(placement: .confirmationAction) {
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            choice = AgentChoice(agentIDs: environment.pipeline.defaultAgentIDsForNewCapture())
        }
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            Task { await capture(photos: selection) }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            CameraPicker { data in
                Task { await capture(imageData: [data], kind: .photo) }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isScannerPresented) {
            DocumentScannerView { pages in
                Task { await capture(imageData: pages, kind: .photo, tags: ["document"]) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Capture actions

    private var options: CaptureService.Options {
        CaptureService.Options(
            agentIDs: choice.agentIDs,
            reminderDate: reminder?.date(relativeTo: Date(), schedule: environment.settings.reminderSchedule)
        )
    }

    private var validLink: URL? {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = TextHeuristics.standaloneURL(in: text) { return url }
        if !text.isEmpty, !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)"), url.host != nil {
            return url
        }
        return nil
    }

    private func capture(providers: [NSItemProvider]) async {
        await perform {
            let items = await environment.capture.capture(providers: providers, options: options)
            return items.count
        }
    }

    private func capture(photos: [PhotosPickerItem]) async {
        await perform {
            var count = 0
            for photo in photos {
                guard let data = try? await photo.loadTransferable(type: Data.self) else { continue }
                // Screenshots in the library are PNG files; camera photos are HEIC or JPEG.
                let kind: CaptureKind = ImageProcessor.fileExtension(for: data) == "png" ? .screenshot : .photo
                if (try? await environment.capture.captureImage(data, kind: kind, options: options)) != nil {
                    count += 1
                }
            }
            return count
        }
        photoSelection = []
    }

    private func capture(imageData: [Data], kind: CaptureKind, tags: [String] = []) async {
        var options = options
        options.tags = tags
        await perform {
            var count = 0
            for data in imageData {
                if (try? await environment.capture.captureImage(data, kind: kind, options: options)) != nil {
                    count += 1
                }
            }
            return count
        }
    }

    private func saveLink() async {
        guard let url = validLink else { return }
        await perform {
            await environment.capture.captureLink(url, options: options)
            return 1
        }
        linkText = ""
    }

    private func saveNote() async {
        let text = noteText
        await perform {
            await environment.capture.captureText(text, options: options) == nil ? 0 : 1
        }
        noteText = ""
    }

    private func perform(_ work: () async -> Int) async {
        isWorking = true
        errorMessage = nil
        let count = await work()
        isWorking = false
        if count > 0 {
            environment.router.showToast(count == 1 ? "Saved to Inbox" : "Saved \(count) captures")
            dismiss()
        } else {
            errorMessage = "Nothing could be captured. Try another item."
        }
    }
}
