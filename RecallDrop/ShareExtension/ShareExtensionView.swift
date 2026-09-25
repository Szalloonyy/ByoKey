//
//  ShareExtensionView.swift
//  RecallDrop Share Extension
//
//  The share sheet UI: preview, note, agent selector, reminder, and the
//  agent's result when it analyzed in place.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct ShareExtensionView: View {
    @Bindable var model: ShareExtensionModel
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("RecallDrop")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        // No Cancel while saving: the items are being written right then.
                        if model.phase != .done && model.phase != .saving {
                            Button("Cancel") { model.cancel() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        switch model.phase {
                        case .ready:
                            Button(model.choice == .none ? "Save" : "Save & Analyze") {
                                Task { await model.save() }
                            }
                            .fontWeight(.semibold)
                        case .done:
                            Button("Done") { model.finish() }
                                .fontWeight(.semibold)
                        case .analyzing:
                            Button("Close") { model.finish() }
                        case .loading, .saving, .failed:
                            EmptyView()
                        }
                    }
                }
        }
        .tint(Color(red: 0.42, green: 0.33, blue: 0.95))
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading shared item…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Save This", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Close") { model.cancel() }
            }
        case .ready, .saving:
            form
                .disabled(model.phase == .saving)
                .overlay {
                    if model.phase == .saving {
                        ProgressView("Saving…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
        case .analyzing(let label):
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(label)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Saved to your inbox. You can close this sheet – RecallDrop finishes the analysis if needed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            resultView
        }
    }

    private var form: some View {
        Form {
            Section {
                preview
            } footer: {
                Text(model.summaryLine)
            }

            Section("Note") {
                TextField("Why are you saving this?", text: $model.note, axis: .vertical)
                    .lineLimit(2...5)
            }

            Section {
                AgentChoiceChips(agents: agents, selection: $model.choice)
            } header: {
                Text("Analyze With")
            } footer: {
                if let reason = model.aiUnavailableReason, case .agent = model.choice {
                    Text("\(reason) The capture gets the on-device analysis now; the agent runs once AI is available.")
                }
            }

            Section {
                Picker("Remind Me", selection: $model.reminder) {
                    Text("No Reminder").tag(ReminderPreset?.none)
                    ForEach(ReminderPreset.allCases) { preset in
                        Text(preset.title).tag(ReminderPreset?.some(preset))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if !model.previewImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.previewImages.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image.cgImage, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        } else if let url = model.previewURL {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(TextHeuristics.sourceAppName(for: url) ?? url.host ?? "Link")
                        .font(.headline)
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } else if let text = model.previewText {
            Text(text)
                .font(.callout)
                .lineLimit(6)
        }
    }

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("Saved to RecallDrop", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if let title = model.resultTitle {
                    Text(title)
                        .font(.title3.weight(.bold))
                }
                if let summary = model.resultSummary {
                    Text(summary)
                        .font(.body)
                }
                if !model.resultSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Next Steps")
                            .font(.subheadline.weight(.semibold))
                        ForEach(model.resultSteps, id: \.self) { step in
                            Label(step, systemImage: "circle")
                                .font(.callout)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
