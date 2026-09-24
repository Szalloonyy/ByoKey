//
//  ItemDetailView.swift
//  RecallDrop
//
//  Everything about one capture: the image, the agent panel (switch agent,
//  re-run, thought breakdown, chat), reminders, extracted text, notes and
//  tags.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct ItemDetailView: View {
    let itemID: UUID
    @Query private var matches: [CapturedItem]

    init(itemID: UUID) {
        self.itemID = itemID
        _matches = Query(filter: #Predicate<CapturedItem> { $0.id == itemID })
    }

    var body: some View {
        if let item = matches.first {
            ItemDetailContent(item: item)
        } else {
            ContentUnavailableView("Capture Not Found", systemImage: "questionmark.square.dashed",
                                   description: Text("It may have been deleted."))
        }
    }
}

struct ItemDetailContent: View {
    @Bindable var item: CapturedItem

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var isImageViewerPresented = false
    @State private var isChatPresented = false
    @State private var isAgentSelectorPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var sharedImageURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeroView(item: item) {
                    isImageViewerPresented = true
                }
                DetailTitleSection(item: item)
                if item.processingState == .failed, let message = item.processingError {
                    FailureBanner(message: message) {
                        environment.pipeline.schedule(item, agentIDs: item.pendingAgentIds.isEmpty
                                                      ? environment.pipeline.defaultAgentIDsForNewCapture()
                                                      : item.pendingAgentIds, prioritized: true)
                    }
                }
                if environment.pipeline.isWaitingForAI(item) {
                    WaitingForAIBanner(reason: environment.settings.aiUnavailableReason) {
                        environment.pipeline.cancel(item.id)
                    }
                }
                AgentPanelView(
                    item: item,
                    onChooseAgents: { isAgentSelectorPresented = true },
                    onChat: { isChatPresented = true }
                )
                ReminderPanel(item: item)
                if item.hasRecognizedText || item.kind == .note {
                    ExtractedTextPanel(item: item)
                }
                NotesPanel(item: item)
                TagEditorPanel(item: item)
            }
            .padding()
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvasBackground)
        .navigationTitle(item.displayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .sheet(isPresented: $isAgentSelectorPresented) {
            AgentSelectorSheet(item: item)
        }
        .sheet(isPresented: $isChatPresented) {
            ChatView(item: item)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isImageViewerPresented) {
            ImageViewerView(item: item)
        }
        #else
        .sheet(isPresented: $isImageViewerPresented) {
            ImageViewerView(item: item)
                .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 760)
        }
        #endif
        .confirmationDialog("Delete this capture?", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("Delete Capture", role: .destructive) {
                let target = item
                dismiss()
                LibraryMaintenance.delete([target], environment: environment)
            }
        } message: {
            Text("The image, text, agent results and chat will be removed from this device.")
        }
        .task(id: item.thumbnailCacheKey) {
            await prepareShareableImage()
        }
        .onDisappear {
            try? item.modelContext?.save()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                item.isPinned.toggle()
                item.touch()
            } label: {
                Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.fill" : "pin")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            shareMenu
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    isAgentSelectorPresented = true
                } label: {
                    Label("Run Agents…", systemImage: "sparkles")
                }
                Button {
                    isChatPresented = true
                } label: {
                    Label("Chat with Capture", systemImage: "bubble.left.and.bubble.right")
                }
                if item.hasImage {
                    Button {
                        environment.pipeline.rerunTextRecognition(on: item)
                    } label: {
                        Label("Read Text Again", systemImage: "text.viewfinder")
                    }
                }
                #if os(macOS)
                Button {
                    openWindow(id: WindowID.item, value: item.id)
                } label: {
                    Label("Open in New Window", systemImage: "macwindow.badge.plus")
                }
                #endif
                Divider()
                Button {
                    item.isArchived.toggle()
                    item.touch()
                } label: {
                    Label(item.isArchived ? "Move to Inbox" : "Archive",
                          systemImage: item.isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private var shareMenu: some View {
        Menu {
            ShareLink(item: item.markdownExport, subject: Text(item.displayTitle)) {
                Label("Share as Text", systemImage: "doc.plaintext")
            }
            if let sharedImageURL {
                ShareLink(item: sharedImageURL) {
                    Label("Share Image", systemImage: "photo")
                }
            }
            if let url = item.sourceURL {
                ShareLink(item: url) {
                    Label("Share Link", systemImage: "link")
                }
            }
            Button {
                Clipboard.copy(item.markdownExport)
                environment.router.showToast("Copied as Markdown")
            } label: {
                Label("Copy as Markdown", systemImage: "doc.on.doc")
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func prepareShareableImage() async {
        guard item.hasImage, let data = item.imageData else {
            sharedImageURL = nil
            return
        }
        let title = item.displayTitle
        sharedImageURL = await Task.detached(priority: .utility) {
            ShareableFiles.imageFile(data: data, title: title)
        }.value
    }
}

/// Red banner with the pipeline's error and a retry button.
struct FailureBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Shown while the chosen agents wait for an AI provider.
struct WaitingForAIBanner: View {
    let reason: String?
    let onStopWaiting: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for AI")
                    .font(.callout.weight(.semibold))
                Text("\(reason ?? "No AI provider is available.") The chosen agent runs as soon as AI is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Don't Wait", action: onStopWaiting)
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Identifiers of the macOS window scenes.
enum WindowID {
    static let main = "main"
    static let item = "item"
}
