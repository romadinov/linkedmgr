import SwiftData
import SwiftUI

/// The content plan: every posting slot for the coming weeks, filled or empty,
/// plus any posts scheduled at custom times.
struct PlanView: View {
    @Binding var selection: PersistentIdentifier?
    let newPost: (Date?) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \Post.createdAt) private var posts: [Post]
    @AppStorage("planWeeks") private var weeks = 4
    @State private var schedule = PostingSchedule.load()

    private struct Row: Identifiable {
        let date: Date
        let post: Post?
        var id: String { post.map { "\($0.id)" } ?? "slot-\(date.timeIntervalSince1970)" }
    }

    private var rows: [Row] {
        let calendar = Calendar.current
        let now = Date()
        let horizon = calendar.date(byAdding: .day, value: weeks * 7, to: now)!
        let scheduled = posts.filter { [.scheduled, .publishing].contains($0.status) && $0.scheduledAt != nil }
        let takenDays = Set(scheduled.map { calendar.startOfDay(for: $0.scheduledAt!) })
        let empty = schedule.upcomingSlots(after: now, limit: weeks * 7)
            .filter { $0 <= horizon && !takenDays.contains(calendar.startOfDay(for: $0)) }
            .map { Row(date: $0, post: nil) }
        return (scheduled.map { Row(date: $0.scheduledAt!, post: $0) } + empty).sorted { $0.date < $1.date }
    }

    private var drafts: [Post] { posts.filter { $0.status == .draft } }

    var body: some View {
        let rows = rows
        List(selection: $selection) {
            ForEach(weekGroups(rows), id: \.start) { group in
                Section(weekTitle(group.start)) {
                    ForEach(group.rows) { row in
                        if let post = row.post {
                            PostRow(post: post).tag(post.persistentModelID)
                                .contextMenu { PostContextMenu(post: post) }
                        } else {
                            EmptySlotRow(date: row.date, drafts: drafts, newPost: newPost) { draft in
                                draft.scheduledAt = row.date
                                draft.status = .scheduled
                                try? context.save()
                                selection = draft.persistentModelID
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No posting days", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("Turn on some weekdays in Settings → Schedule."))
            }
        }
        .navigationTitle("Content Plan")
        .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Fill Empty Slots with Drafts") { fillSlots() }.disabled(drafts.isEmpty)
                    Picker("Show", selection: $weeks) {
                        ForEach([2, 4, 8, 12], id: \.self) { Text("\($0) weeks").tag($0) }
                    }
                } label: { Label("Plan", systemImage: "wand.and.stars") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let latest = PostingSchedule.load()
            if latest != schedule { schedule = latest }
        }
    }

    /// Puts drafts, oldest first, into the next free slots.
    private func fillSlots() {
        for draft in drafts.sorted(by: { $0.createdAt < $1.createdAt }) {
            Scheduling.scheduleNextFree(draft, context: context)
        }
    }

    private struct WeekGroup { let start: Date; let rows: [Row] }

    private func weekGroups(_ rows: [Row]) -> [WeekGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { calendar.dateInterval(of: .weekOfYear, for: $0.date)!.start }
        return grouped.keys.sorted().map { WeekGroup(start: $0, rows: grouped[$0]!) }
    }

    private func weekTitle(_ start: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(start, equalTo: Date(), toGranularity: .weekOfYear) { return "This week" }
        if let next = calendar.date(byAdding: .weekOfYear, value: 1, to: Date()),
           calendar.isDate(start, equalTo: next, toGranularity: .weekOfYear) { return "Next week" }
        return "Week of \(start.formatted(.dateTime.day().month(.wide)))"
    }
}

private struct EmptySlotRow: View {
    let date: Date
    let drafts: [Post]
    let newPost: (Date?) -> Void
    let assign: (Post) -> Void

    var body: some View {
        HStack {
            Image(systemName: "calendar.badge.plus").foregroundStyle(.tertiary).frame(width: 44)
            VStack(alignment: .leading) {
                Text(date.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                Text("Empty slot").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("New Post for This Slot") { newPost(date) }
                if !drafts.isEmpty {
                    Section("Drafts") {
                        ForEach(drafts) { draft in
                            Button(draft.displayTitle) { assign(draft) }
                        }
                    }
                }
            } label: { Image(systemName: "plus.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .foregroundStyle(.secondary)
    }
}
