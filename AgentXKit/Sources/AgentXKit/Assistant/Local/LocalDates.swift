import Foundation

/// Dates and times in what you typed ("tomorrow at 1pm", "friday 3pm", "at 6",
/// "in 2 hours"). macOS's own date reader (NSDataDetector) does most of it;
/// this fills its gaps: bare times like "at 6", "in N minutes", and telling a
/// date ("tomorrow", which it reads as noon) from a date and time.
enum LocalDates {
    struct When: Equatable {
        var date: Date
        /// False for a day without a time ("tomorrow"): an all-day reminder, a 9:00 event.
        var hasTime: Bool
    }

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> When? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // "in 20 minutes", "in 2 hours", "in 3 days".
        if let m = t.firstMatch(of: /\bin (\d{1,3}) ?(min(?:ute)?s?|hours?|hrs?|days?|weeks?)\b/) {
            let n = Int(m.1) ?? 0, unit = String(m.2)
            let (component, hasTime): (Calendar.Component, Bool) = unit.hasPrefix("min") ? (.minute, true)
                : unit.hasPrefix("h") ? (.hour, true) : unit.hasPrefix("d") ? (.day, false) : (.weekOfYear, false)
            guard let date = calendar.date(byAdding: component, value: n, to: now) else { return nil }
            return When(date: hasTime ? date : calendar.startOfDay(for: date), hasTime: hasTime)
        }

        let typedTime = explicitTime(in: t)
        var when: When?
        if let detected = detect(t) {
            when = When(date: detected.date, hasTime: typedTime != nil || mentionsTimeOfDay(detected.text))
        }
        // A time the detector missed or read as morning ("tomorrow at 6", "at 6").
        if let (hour, minute, saidAmPm) = typedTime {
            let day = when.map { calendar.startOfDay(for: $0.date) } ?? calendar.startOfDay(for: now)
            let h = saidAmPm ? hour : (1...7).contains(hour) ? hour + 12 : hour
            if let date = calendar.date(bySettingHour: h, minute: minute, second: 0, of: day) {
                when = When(date: date, hasTime: true)
            }
        }
        guard var result = when else { return nil }
        if !result.hasTime { result.date = calendar.startOfDay(for: result.date) }
        // "at 8" when it's already 9: tomorrow, unless a day was named.
        if result.hasTime, result.date < now, !namesADay(t) {
            result.date = calendar.date(byAdding: .day, value: 1, to: result.date) ?? result.date
        }
        return result
    }

    /// When a period people use about files starts ("today", "this week", "last month", "past 3 days").
    static func since(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let t = text.lowercased()
        let today = calendar.startOfDay(for: now)
        func start(of c: Calendar.Component, back: Int = 0) -> Date? {
            calendar.date(byAdding: c, value: -back, to: now).flatMap { calendar.dateInterval(of: c, for: $0)?.start }
        }
        if let m = t.firstMatch(of: /(?:last|past) (\d{1,3}) days?/), let n = Int(m.1) { return calendar.date(byAdding: .day, value: -n, to: today) }
        if t.contains("today") { return today }
        if t.contains("yesterday") { return calendar.date(byAdding: .day, value: -1, to: today) }
        if t.contains("last week") || t.contains("past week") { return start(of: .weekOfYear, back: 1) }
        if t.contains("this week") { return start(of: .weekOfYear) }
        if t.contains("last month") || t.contains("past month") { return start(of: .month, back: 1) }
        if t.contains("this month") { return start(of: .month) }
        if t.contains("this year") { return start(of: .year) }
        return nil
    }

    /// "at 6", "6pm", "6:30", "at 7:15 am" → (hour, minute, whether am/pm was said).
    static func explicitTime(in t: String) -> (Int, Int, Bool)? {
        var found: (hour: Int, minute: Int, ampm: String)?
        if let m = t.firstMatch(of: /\b(\d{1,2})(?::(\d{2}))? ?(a\.?m\.?|p\.?m\.?)(?![a-z])/) {
            found = (Int(m.1) ?? 99, m.2.flatMap { Int($0) } ?? 0, String(m.3))
        } else if let m = t.firstMatch(of: /\bat (\d{1,2})(?::(\d{2}))?\b(?! ?(?:%|percent|minutes|mins|hours|days))/) {
            found = (Int(m.1) ?? 99, m.2.flatMap { Int($0) } ?? 0, "")
        } else if let m = t.firstMatch(of: /(?:^|[^\d:])(\d{1,2}):(\d{2})\b/) {
            found = (Int(m.1) ?? 99, Int(m.2) ?? 99, "")
        }
        guard let f = found, f.hour <= 23, f.minute < 60 else { return nil }
        var hour = f.hour
        let minute = f.minute, ampm = f.ampm
        if ampm.hasPrefix("p"), hour < 12 { hour += 12 }
        if ampm.hasPrefix("a"), hour == 12 { hour = 0 }
        return (hour, minute, !ampm.isEmpty || hour > 12 || hour == 0)
    }

    private static func detect(_ t: String) -> (date: Date, text: String)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let date = match.date,
              let range = Range(match.range, in: t) else { return nil }
        return (date, String(t[range]))
    }

    private static func mentionsTimeOfDay(_ t: String) -> Bool {
        t.range(of: #"\b(noon|midday|midnight|morning|afternoon|evening|tonight|night)\b"#, options: .regularExpression) != nil
    }

    private static func namesADay(_ t: String) -> Bool {
        t.range(of: #"\b(today|tonight|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next|\d{1,2}(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2})\b"#,
                options: .regularExpression) != nil
    }
}
