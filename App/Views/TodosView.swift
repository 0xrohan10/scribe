import Core
import SwiftUI

struct TodosView: View {
    let app: AppModel
    @Bindable var model: TodosModel
    @State private var draft = ""
    @State private var editing: TodoItem?
    @State private var deleting: TodoItem?
    @FocusState private var addingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Todos").font(Theme.serif(30))
                Text("\(model.openCount) open · Add your own tasks or follow up on meeting action items.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(.top, 28)
            ComposerCard(isFocused: addingFocused) {
                HStack(spacing: 10) {
                    TextField("Add a todo…", text: $draft)
                        .textFieldStyle(.plain)
                        .disabled(model.isSaving)
                        .focused($addingFocused)
                        .accessibilityIdentifier("todo.new")
                        .onSubmit(add)
                    Button("Add", systemImage: "plus", action: add)
                        .buttonStyle(QuietButtonStyle())
                        .disabled(model.isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("todo.add")
                }
            }
            HStack {
                PillTabs(selection: $model.filter, options: TodoFilter.allCases.map { ($0, $0.rawValue) })
                Spacer(minLength: 12)
                TextField("Search todos", text: $model.query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .accessibilityIdentifier("todo.search")
            }
            if model.filter == .today {
                Text("Due today or overdue. Unconfirmed date suggestions stay in Open.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            if let error = model.lastError {
                HStack {
                    Text(error).foregroundStyle(Theme.recording)
                    Spacer()
                    Button("Dismiss") { model.lastError = nil }.buttonStyle(.borderless)
                }.font(.system(size: 12))
            }
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.isLoading && model.items.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(40)
                        } else if model.visibleItems.isEmpty {
                            Text(emptyMessage).foregroundStyle(Theme.secondary).padding(.vertical, 40)
                        }
                        ForEach(model.visibleItems) { item in
                            row(item)
                            Rectangle().fill(Theme.border).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.reload() }
        .onAppear { addingFocused = true }
        .sheet(item: $editing) { TodoEditor(item: $0, model: model) }
        .confirmationDialog("Delete “\(deleting?.title ?? "todo")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let item = deleting {
                Button("Delete Todo", role: .destructive) { deleting = nil; Task { await model.delete(item) } }
            }
        } message: { Text("Meeting transcripts and summaries are not changed. Deleted imported tasks will not return when the same action is summarized again.") }
    }

    private func row(_ item: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { Task { await model.toggle(item) } } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(item.isCompleted ? Theme.highlight : Theme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Reopen \(item.title)" : "Complete \(item.title)")
            .accessibilityIdentifier("todo.toggle")
            VStack(alignment: .leading, spacing: 6) {
                Button { editing = item } label: {
                    Text(item.title).font(.system(size: 15)).strikethrough(item.isCompleted)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(item.isCompleted ? Theme.secondary : Theme.text)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("todo.edit")
                if !item.notes.isEmpty { Text(item.notes).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2) }
                HStack(spacing: 10) {
                    if let owner = item.owner { Label(owner, systemImage: "person").font(.system(size: 12)) }
                    if let due = item.dueDate {
                        Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.system(size: 12)).foregroundStyle(!item.isCompleted && due < Calendar.current.startOfDay(for: .now) ? Theme.recording : Theme.secondary)
                    } else if let suggestion = item.suggestedDue {
                        Button("Confirm date: \(suggestion)") { editing = item }.buttonStyle(.borderless).font(.system(size: 12))
                    }
                }.foregroundStyle(Theme.secondary)
                if let title = item.meetingTitle {
                    if item.meetingID != nil {
                        Button { app.openTodoSource(item) } label: { Label(title, systemImage: "doc.text").lineLimit(1) }
                            .buttonStyle(.borderless).font(.system(size: 12))
                            .accessibilityIdentifier("todo.source")
                    } else {
                        Text("\(title) · meeting deleted").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Edit") { editing = item }
                Button("Delete…", role: .destructive) { deleting = item }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Todo actions")
        }
        .padding(.vertical, 16)
        .disabled(model.isSaving)
        .accessibilityElement(children: .contain)
    }

    private var emptyMessage: String {
        if !model.query.isEmpty { return "No matching todos." }
        switch model.filter {
        case .open: return "No open todos. Add one above; meeting action items will appear here too."
        case .today: return "Nothing due today or overdue."
        case .completed: return "Completed todos appear here."
        }
    }

    private func add() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !model.isSaving else { return }
        Task { if await model.save(TodoItem(title: title)) { draft = ""; model.filter = .open; addingFocused = true } }
    }
}

struct TodoEditor: View {
    let item: TodoItem
    let model: TodosModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var owner: String
    @State private var notes: String
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var suggestion: String?
    @FocusState private var titleFocused: Bool

    init(item: TodoItem, model: TodosModel) {
        self.item = item
        self.model = model
        _title = State(initialValue: item.title)
        _owner = State(initialValue: item.owner ?? "")
        _notes = State(initialValue: item.notes)
        _hasDate = State(initialValue: item.dueDate != nil)
        _date = State(initialValue: item.dueDate ?? .now)
        _suggestion = State(initialValue: item.suggestedDue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(item.title.isEmpty ? "New todo" : "Edit todo").font(Theme.serif(26))
            Form {
                TextField("Title", text: $title).focused($titleFocused).accessibilityIdentifier("todo.editor.title")
                TextField("Owner (optional)", text: $owner).accessibilityIdentifier("todo.editor.owner")
                Toggle("Set a due date", isOn: $hasDate).accessibilityIdentifier("todo.editor.hasDate")
                if hasDate { DatePicker("Due", selection: $date, displayedComponents: .date) }
                if let suggestion, !hasDate {
                    HStack {
                        Text("Meeting suggested “\(suggestion)”. Choose a date to confirm.").font(.system(size: 12))
                        Button("Clear suggestion") { self.suggestion = nil }.buttonStyle(.borderless)
                    }
                }
                LabeledContent("Notes") {
                    TextEditor(text: $notes).frame(height: 100).font(.system(size: 13)).accessibilityLabel("Todo notes")
                }
                if let source = item.meetingTitle { LabeledContent("From", value: source) }
            }
            if let error = model.lastError { Text(error).font(.system(size: 12)).foregroundStyle(Theme.recording) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isSaving)
                Spacer()
                Button("Save") {
                    var edited = item
                    edited.title = title
                    edited.owner = owner
                    edited.notes = notes
                    edited.dueDate = hasDate ? Calendar.current.startOfDay(for: date) : nil
                    edited.suggestedDue = hasDate ? nil : suggestion
                    Task { if await model.save(edited) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("todo.editor.save")
            }
        }
        .padding(24)
        .frame(width: 520)
        .foregroundStyle(Theme.text)
        .interactiveDismissDisabled(model.isSaving)
        .onAppear { model.lastError = nil; titleFocused = true }
    }
}
