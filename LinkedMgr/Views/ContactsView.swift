import SwiftData
import SwiftUI

struct ContactsList: View {
    @Binding var selection: PersistentIdentifier?
    @Environment(\.modelContext) private var context
    @Query(sort: \Contact.name) private var contacts: [Contact]

    var body: some View {
        List(selection: $selection) {
            ForEach(contacts) { contact in
                HStack {
                    Image(systemName: contact.kind.symbol).frame(width: 20)
                    VStack(alignment: .leading) {
                        Text(contact.name.isEmpty ? "New contact" : contact.name)
                        Text(contact.urn.isEmpty ? "Tag by hand after publishing" : contact.urn)
                            .font(.caption).foregroundStyle(contact.urn.isEmpty ? .orange : .secondary)
                            .lineLimit(1)
                    }
                }
                .tag(contact.persistentModelID)
                .contextMenu {
                    Button("Delete", role: .destructive) { context.delete(contact); try? context.save() }
                }
            }
        }
        .overlay {
            if contacts.isEmpty {
                ContentUnavailableView("No people or companies", systemImage: "person.2",
                                       description: Text("Add the people and companies you tag often."))
            }
        }
        .navigationTitle("People & Companies")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Person") { add(.person) }
                    Button("Company") { add(.organization) }
                } label: { Label("Add", systemImage: "person.badge.plus") }
            }
        }
    }

    private func add(_ kind: ContactKind) {
        let contact = Contact(name: "", kind: kind)
        context.insert(contact)
        try? context.save()
        selection = contact.persistentModelID
    }
}

struct ContactEditor: View {
    @Bindable var contact: Contact
    @Environment(\.modelContext) private var context
    @State private var vanity = ""
    @State private var lookupMessage: String?
    @State private var looking = false

    var body: some View {
        Form {
            Picker("Type", selection: Binding(get: { contact.kind }, set: { contact.kind = $0 })) {
                ForEach(ContactKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Name on LinkedIn", text: $contact.name, prompt: Text(contact.kind == .person ? "Jane Smith" : "Acme Inc."))
            TextField("URN", text: $contact.urn,
                      prompt: Text(contact.kind == .person ? "urn:li:person:…" : "urn:li:organization:…"))
                .font(.body.monospaced())
            TextField("Profile / page URL", text: $contact.profileURL)
            TextField("Note", text: $contact.note, axis: .vertical)

            if contact.kind == .organization {
                Section("Find company URN") {
                    HStack {
                        TextField("linkedin.com/company/…", text: $vanity, prompt: Text("company page URL or vanity name"))
                        Button("Look Up") { Task { await lookup() } }
                            .disabled(vanity.isEmpty || looking || !LinkedInAccount.shared.isConnected)
                    }
                    if let lookupMessage { Text(lookupMessage).font(.caption).foregroundStyle(.secondary) }
                    Text("If lookup is refused, the numeric company ID is in the page's source as “fsd_company:12345”, "
                         + "or in a LinkedIn people-search URL filtered by that company (currentCompany=…). "
                         + "The URN is urn:li:organization:12345.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("About tagging people") {
                    Text("LinkedIn's self-serve API doesn't let apps look up other members' IDs, so most people "
                         + "can't be auto-tagged. Leave the URN empty: the name is published as plain text and "
                         + "LinkedMgr reminds you to add the tag by editing the post on LinkedIn. If you do have "
                         + "someone's urn:li:person ID, paste it here and the tag goes out automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("The name must match their LinkedIn name exactly (case-sensitive), or LinkedIn shows plain text.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle(contact.name.isEmpty ? "New contact" : contact.name)
        .onDisappear { try? context.save() }
    }

    private func lookup() async {
        guard let client = LinkedInAccount.shared.client else { return }
        looking = true
        defer { looking = false }
        var name = vanity.trimmingCharacters(in: .whitespaces)
        if let range = name.range(of: "/company/") {
            name = String(name[range.upperBound...]).split(separator: "/").first.map(String.init) ?? name
        }
        do {
            if let org = try await client.lookupOrganization(vanityName: name) {
                contact.urn = org.urn
                if contact.name.isEmpty { contact.name = org.name }
                lookupMessage = "Found \(org.name)."
            } else {
                lookupMessage = "No company with that vanity name."
            }
        } catch {
            lookupMessage = error.localizedDescription
        }
    }
}
