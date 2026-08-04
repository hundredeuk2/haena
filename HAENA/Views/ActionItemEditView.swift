import SwiftUI

/// Sheet for correcting the two fields extraction most often leaves blank: who owns a task and
/// when it is due.
///
/// The assignee choices are exactly the meeting's participants plus "미지정". There is no free-text
/// name field on purpose — the extractor refuses to invent an owner, and this screen must not
/// become the back door that attaches one who was never in the meeting.
struct ActionItemEditView: View {
    let actionItem: ActionItem
    let participants: [Participant]
    let onSave: (UUID?, Date?) async -> Void
    let onCancel: () -> Void

    @State private var selectedAssigneeID: UUID?
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var isSaving = false

    init(
        actionItem: ActionItem,
        participants: [Participant],
        onSave: @escaping (UUID?, Date?) async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.actionItem = actionItem
        self.participants = participants
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedAssigneeID = State(initialValue: actionItem.assigneeID)
        _hasDueDate = State(initialValue: actionItem.dueDate != nil)
        _dueDate = State(initialValue: actionItem.dueDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("업무 수정")
                .font(.headline)

            Text(actionItem.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("edit-action-item-title")

            Picker("담당자", selection: $selectedAssigneeID) {
                Text("미지정").tag(UUID?.none)
                ForEach(participants) { participant in
                    Text(participant.displayName).tag(Optional(participant.id))
                }
            }
            .accessibilityIdentifier("action-item-assignee-picker")

            Toggle("마감일 지정", isOn: $hasDueDate)
                .accessibilityIdentifier("action-item-due-date-toggle")

            if hasDueDate {
                DatePicker("마감일", selection: $dueDate, displayedComponents: .date)
                    .accessibilityIdentifier("action-item-due-date-picker")
            }

            HStack {
                Button("취소") {
                    onCancel()
                }
                .accessibilityIdentifier("cancel-edit-action-item-button")

                Spacer()

                Button("저장") {
                    isSaving = true
                    Task {
                        await onSave(selectedAssigneeID, hasDueDate ? dueDate : nil)
                        isSaving = false
                    }
                }
                .disabled(isSaving)
                .accessibilityIdentifier("save-action-item-button")
            }
        }
        .padding(24)
        .frame(minWidth: 380)
    }
}
