//
//  ChatView.swift
//  RecallDrop
//
//  "Chat with Screenshot": ask follow-up questions about a capture in the
//  voice of any agent. Answers stream in and are kept with the item.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct ChatView: View {
    let item: CapturedItem

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var session: ChatSession?
    @State private var draft = ""
    @State private var selectedAgentID: UUID?
    @State private var includeImage = true
    @FocusState private var isComposerFocused: Bool

    private var selectedAgent: AgentConfig? {
        agents.first { $0.id == selectedAgentID }
            ?? agents.first { $0.id == item.lastUsedAgentId }
            ?? agents.first(where: \.isDefault)
            ?? agents.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider()
                composer
            }
            .navigationTitle("Chat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    agentMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        session?.clearConversation(of: item)
                    } label: {
                        Label("Clear Chat", systemImage: "trash")
                    }
                    .disabled(item.chatMessages.isEmpty)
                }
            }
        }
        .task {
            if session == nil {
                session = ChatSession(environment: environment)
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 560, idealHeight: 720)
        #endif
    }

    // MARK: Transcript

    private var transcript: some View {
        let messages = item.sortedChatMessages
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    contextHeader
                    if messages.isEmpty, session?.isStreaming != true {
                        suggestions
                    }
                    ForEach(messages) { message in
                        ChatBubble(role: message.role, text: message.content, agentName: message.agentName,
                                   isError: message.isError)
                            .id(message.id)
                    }
                    if let session, session.isStreaming {
                        ChatBubble(role: .assistant,
                                   text: session.streamingText.isEmpty ? "…" : session.streamingText,
                                   agentName: selectedAgent?.displayName, isError: false)
                            .id("streaming")
                    }
                    if let error = session?.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(10)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .id("error")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session?.streamingText ?? "") { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var contextHeader: some View {
        HStack(spacing: 10) {
            if item.hasImage {
                CaptureImageView(cacheKey: item.thumbnailCacheKey, data: item.thumbnailData, maxPixelSize: 200)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("The agent sees the \(sendsImage ? "image, " : "")text, summary and your notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this capture")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout {
                ForEach(AgentPromptBuilder.suggestedChatPrompts, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.placeholderFill, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if item.hasImage, environment.settings.sendImages {
                Button {
                    includeImage.toggle()
                } label: {
                    Image(systemName: includeImage ? "photo.fill" : "photo")
                        .imageScale(.large)
                        .foregroundStyle(includeImage ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(includeImage ? "The image is sent with each message" : "Only text is sent")
                .accessibilityLabel(includeImage ? "Image included" : "Image not included")
            }

            TextField("Ask \(selectedAgent?.displayName ?? "the agent")…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.placeholderFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($isComposerFocused)
                .onSubmit { send(draft) }

            if session?.isStreaming == true {
                Button {
                    session?.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            } else {
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmedNonEmpty == nil ? Color.secondary : Color.accentColor)
                .disabled(draft.trimmedNonEmpty == nil)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
        }
        .padding(12)
    }

    private var agentMenu: some View {
        Menu {
            ForEach(agents) { agent in
                Button {
                    selectedAgentID = agent.id
                } label: {
                    if agent.id == selectedAgent?.id {
                        Label("\(agent.emoji) \(agent.displayName)", systemImage: "checkmark")
                    } else {
                        Text("\(agent.emoji) \(agent.displayName)")
                    }
                }
            }
        } label: {
            Label(selectedAgent.map { "\($0.emoji) \($0.displayName)" } ?? "Agent", systemImage: "person.crop.circle")
        }
    }

    /// Whether the image goes along: the capture has one, the chat includes it
    /// and "Send Images to the Model" is on.
    private var sendsImage: Bool {
        item.hasImage && includeImage && environment.settings.sendImages
    }

    private func send(_ text: String) {
        guard let session, let agent = selectedAgent, text.trimmedNonEmpty != nil else { return }
        // A reply that is still streaming keeps the draft for the next try.
        if session.send(text, about: item, persona: agent.persona, includeImage: includeImage) {
            draft = ""
        }
    }
}

private struct ChatBubble: View {
    let role: ChatRole
    let text: String
    let agentName: String?
    let isError: Bool

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 40) }
            VStack(alignment: role == .user ? .trailing : .leading, spacing: 4) {
                if role == .assistant, let agentName {
                    Text(agentName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Group {
                    if role == .assistant {
                        MarkdownText(markdown: text)
                    } else {
                        Text(text)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(role == .user ? Color.white : Color.primary)
            }
            if role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        if isError { return Color.red.opacity(0.12) }
        return role == .user ? Color.accentColor : Theme.placeholderFill
    }
}
