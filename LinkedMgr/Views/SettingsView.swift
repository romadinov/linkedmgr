import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings().tabItem { Label("LinkedIn", systemImage: "person.crop.circle") }
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "calendar") }
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}

private struct AccountSettings: View {
    @Bindable private var account = LinkedInAccount.shared

    var body: some View {
        Form {
            Section {
                if account.isConnected {
                    LabeledContent("Connected as", value: account.memberName ?? account.personURN ?? "")
                    if let exp = account.tokenExpiresAt {
                        LabeledContent("Sign-in valid until", value: exp.formatted(date: .long, time: .shortened))
                    }
                    HStack {
                        Button("Reconnect") { Task { await account.signIn() } }
                        Button("Disconnect", role: .destructive) { account.signOut() }
                    }
                } else {
                    Button(account.isSigningIn ? "Waiting for browser…" : "Connect LinkedIn") {
                        Task { await account.signIn() }
                    }
                    .disabled(account.isSigningIn)
                }
                if let error = account.lastError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }

            Section("Your LinkedIn developer app") {
                TextField("Client ID", text: $account.clientID)
                SecureField("Client Secret", text: $account.clientSecret)
                LabeledContent("Redirect URL") {
                    HStack {
                        Text(LinkedInAccount.redirectURI).font(.body.monospaced()).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(LinkedInAccount.redirectURI, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    }
                }
                Text("""
                One-time setup at linkedin.com/developers/apps: create an app (it must be linked to a \
                company page), add the products “Share on LinkedIn” and “Sign In with LinkedIn using \
                OpenID Connect”, and under Auth add the redirect URL above. Copy the Client ID and \
                Secret here. Sign-ins last 60 days; LinkedMgr warns you a week before.
                """)
                .font(.caption).foregroundStyle(.secondary)
                Link("Open LinkedIn Developer Portal", destination: URL(string: "https://www.linkedin.com/developers/apps")!)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScheduleSettings: View {
    @State private var schedule = PostingSchedule.load()
    @State private var newSkipDay = Date()
    @State private var graceHours = PublishEngine.graceHours
    @State private var wakeMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(weekdayOrder, id: \.self) { weekday in
                    let binding = slotBinding(weekday)
                    HStack {
                        Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: binding.enabled)
                            .frame(width: 140, alignment: .leading)
                        Spacer()
                        DatePicker("", selection: timeBinding(weekday), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .disabled(!binding.wrappedValue.enabled)
                    }
                }
                Button("Reset to Recommended Times") { schedule = .default }
            } header: {
                Text("Posting days and times")
            } footer: {
                Text("""
                Defaults are weekdays mid-morning, leaning on Wed–Thu, where 2026 studies (Sprout Social, \
                Buffer) see the most engagement. Your audience may differ — check your post analytics after \
                a few weeks and adjust.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Days off (holidays, vacation)") {
                HStack {
                    DatePicker("Skip", selection: $newSkipDay, displayedComponents: .date)
                    Button("Add") {
                        let day = Calendar.current.startOfDay(for: newSkipDay)
                        if !schedule.skipDays.contains(day) { schedule.skipDays.append(day); schedule.skipDays.sort() }
                    }
                }
                ForEach(schedule.skipDays.filter { $0 >= Calendar.current.startOfDay(for: Date()) }, id: \.self) { day in
                    HStack {
                        Text(day.formatted(date: .complete, time: .omitted))
                        Spacer()
                        Button { schedule.skipDays.removeAll { $0 == day } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                Stepper("Still publish up to \(graceHours) h late", value: $graceHours, in: 0...12)
                    .onChange(of: graceHours) { _, v in PublishEngine.graceHours = v }
                Button("Wake This Mac Before Posting Time…") { scheduleWake() }
                if let wakeMessage { Text(wakeMessage).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("If the Mac is asleep")
            } footer: {
                Text("""
                LinkedIn can't schedule personal posts itself, so the background publisher must be on \
                (Settings ▸ General) and the Mac awake. A post that falls due while the Mac sleeps goes out on wake within the window above, otherwise it's \
                marked Missed. “Wake This Mac” sets a daily power-on/wake (pmset, asks for your password) \
                5 minutes before your earliest posting time; it works on power, not with the lid closed on battery.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: schedule) { _, s in s.save() }
    }

    /// Monday-first, as working weeks are usually read.
    private var weekdayOrder: [Int] { [2, 3, 4, 5, 6, 7, 1] }

    private func slotBinding(_ weekday: Int) -> Binding<PostingSchedule.Slot> {
        Binding(get: { schedule.slot(forWeekday: weekday) }, set: { schedule.slots[weekday] = $0 })
    }

    private func timeBinding(_ weekday: Int) -> Binding<Date> {
        Binding(
            get: {
                let s = schedule.slot(forWeekday: weekday)
                return Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date())!
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                var s = schedule.slot(forWeekday: weekday)
                s.hour = c.hour ?? 10
                s.minute = c.minute ?? 0
                schedule.slots[weekday] = s
            })
    }

    private func scheduleWake() {
        let enabled = schedule.slots.filter { $0.value.enabled }
        guard let earliest = enabled.values.map({ $0.hour * 60 + $0.minute }).min() else {
            wakeMessage = "Turn on at least one posting day first."
            return
        }
        let letters: [Int: String] = [1: "U", 2: "M", 3: "T", 4: "W", 5: "R", 6: "F", 7: "S"]
        let days = enabled.keys.sorted().compactMap { letters[$0] }.joined()
        let minutes = max(earliest - 5, 0)
        let time = String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
        let script = "do shell script \"pmset repeat wakeorpoweron \(days) \(time)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        wakeMessage = error == nil
            ? "The Mac will wake every \(days) at \(time.dropLast(3))."
            : "Not changed: \(error?[NSAppleScript.errorMessage] as? String ?? "cancelled")."
    }
}

private struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("apiVersion") private var apiVersion = "202610"
    @State private var loginError: String?

    var body: some View {
        Form {
            BackgroundPublisherSection()
            Section {
                Toggle("Open LinkedMgr at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Text("Optional — only for the menu bar icon. Publishing is done by the background publisher, app open or not.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Advanced") {
                TextField("LinkedIn API version (YYYYMM)", text: $apiVersion)
                Text("LinkedIn retires API versions after about a year. If publishing fails with a version error, set a newer month.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Turns the background publisher (the launchd agent) on and off.
struct BackgroundPublisherSection: View {
    @State private var status = Agent.service.status
    @State private var error: String?

    var body: some View {
        Section {
            LabeledContent("Background publisher") {
                Label(statusText, systemImage: status == .enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status == .enabled ? .green : .orange)
            }
            HStack {
                switch status {
                case .enabled:
                    Button("Turn Off") { change { try Agent.service.unregister() } }
                case .requiresApproval:
                    Button("Open Login Items Settings…") { SMAppService.openSystemSettingsLoginItems() }
                default:
                    Button("Turn On") { change { try Agent.service.register() } }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("""
            Publishes scheduled posts and first comments in the background, whether or not this \
            window is open, and starts automatically when you log in. macOS lists it under \
            System Settings ▸ General ▸ Login Items & Extensions as “LinkedMgr”; it must be allowed there. \
            Keep LinkedMgr in /Applications — moving the app breaks the publisher until you turn it off and on.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            // Approval happens in System Settings, so keep polling while visible.
            while !Task.isCancelled {
                status = Agent.service.status
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var statusText: String {
        switch status {
        case .enabled: "Running"
        case .requiresApproval: "Needs approval in System Settings"
        case .notRegistered: "Off — scheduled posts won't go out"
        case .notFound: "Not found in app bundle"
        @unknown default: "Unknown"
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = Agent.service.status
        if status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
