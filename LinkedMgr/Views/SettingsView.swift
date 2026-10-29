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
    @State private var graceHours = Publisher.shared.graceHours
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
                    .onChange(of: graceHours) { _, v in Publisher.shared.graceHours = v }
                Button("Wake This Mac Before Posting Time…") { scheduleWake() }
                if let wakeMessage { Text(wakeMessage).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("If the Mac is asleep")
            } footer: {
                Text("""
                LinkedIn can't schedule personal posts itself, so LinkedMgr must be running. A post that \
                falls due while the Mac sleeps goes out on wake within the window above, otherwise it's \
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
                Text("Recommended: scheduled posts only go out while LinkedMgr is running. Closing the window keeps it in the menu bar.")
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
