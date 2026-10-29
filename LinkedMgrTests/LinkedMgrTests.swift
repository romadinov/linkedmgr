import Foundation
import Testing
@testable import LinkedMgr

struct LittleTextTests {
    @Test func escapesReservedCharactersButKeepsHashtags() {
        #expect(LittleText.commentary("Hi (all) * see #swift and C# _x_") == ##"Hi \(all\) \* see #swift and C\# \_x\_"##)
    }

    @Test func resolvedMentionsPassThrough() {
        let text = "Thanks @[Acme Corp](urn:li:organization:42) and @[Jane](urn:li:person:abc)!"
        #expect(LittleText.commentary(text) == "Thanks @[Acme Corp](urn:li:organization:42) and @[Jane](urn:li:person:abc)!")
    }

    @Test func unresolvedMentionsBecomePlainText() {
        let text = "Great talk by @[Jane Doe]() today"
        #expect(LittleText.commentary(text) == "Great talk by Jane Doe today")
        #expect(LittleText.unresolvedMentions(text) == ["Jane Doe"])
    }

    @Test func commentAttributesUseUTF16Offsets() {
        let message = LittleText.commentMessage("🚀 Link: https://x.io via @[Acme](urn:li:organization:1)")
        #expect(message.text == "🚀 Link: https://x.io via Acme")
        #expect(message.attributes == [.init(start: 26, length: 4, urn: "urn:li:organization:1")])
    }
}

struct PostingScheduleTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Melbourne")!
        return c
    }

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func skipsWeekendsAndPastTimes() {
        // Friday 2026-10-30 at noon: Friday's 10:00 slot has passed, so next is Monday.
        let slots = PostingSchedule.default.upcomingSlots(after: date(2026, 10, 30, 12), limit: 2, calendar: calendar)
        #expect(slots == [date(2026, 11, 2, 10), date(2026, 11, 3, 10, 30)])
    }

    @Test func nextFreeSlotSkipsTakenDaysAndDaysOff() {
        var schedule = PostingSchedule.default
        schedule.skipDays = [date(2026, 11, 3)]
        let slot = schedule.nextFreeSlot(after: date(2026, 11, 1), taken: [date(2026, 11, 2, 15)], calendar: calendar)
        #expect(slot == date(2026, 11, 4, 11))
    }
}
