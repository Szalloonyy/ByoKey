//
//  NewNoteSheet.swift
//  RecallDrop
//
//  Jot down a fleeting idea, pick an agent and optionally a reminder.
//

import SwiftUI
import SwiftData
import RecallDropKit

struct NewNoteSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\AgentConfig.sortOrder), SortDescriptor(\AgentConfig.createdAt)])
    private var agents: [AgentConfig]

    @State private var text = ""
    @State private var choice: AgentChoice = .none
    @State private var reminder: ReminderPreset?
    @State private var isSaving = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .focused($isEditorFocused)
                } header: {
                    Text("Fleeting Idea")
                } footer: {
                    Text("A pasted link is saved as a link capture with a preview.")
                }

                Section("Analyze With") {
                    AgentChoiceChips(agents: agents, selection: $choice)
                }

                Section {
                    Picker("Remind Me", selection: $reminder) {
                        Text("No Reminder").tag(ReminderPreset?.none)
                        ForEach(ReminderPreset.allCases) { preset in
                            Text(preset.title).tag(ReminderPreset?.some(preset))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(text.trimmedNonEmpty == nil || isSaving)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .onAppear {
                choice = AgentChoice(agentIDs: environment.pipeline.defaultAgentIDsForNewCapture())
                isEditorFocused = true
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let reminderDate = reminder?.date(relativeTo: Date(), schedule: environment.settings.reminderSchedule)
        let options = CaptureService.Options(agentIDs: choice.agentIDs, reminderDate: reminderDate)
        if await environment.capture.captureText(text, options: options) != nil {
            environment.router.showToast("Saved to Inbox")
            dismiss()
        }
    }
}
