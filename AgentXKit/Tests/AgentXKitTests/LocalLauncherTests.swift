import Foundation
import Testing
@testable import AgentXKit

@Suite("Launcher on this Mac")
struct LocalLauncherTests {
    @Test func sumsAreWorkedOutSafely() {
        #expect(Calculator.evaluate("12*4.5") == 54)
        #expect(Calculator.evaluate("(3+4)^2") == 49)
        #expect(Calculator.evaluate("2 + 3 × 4") == 14)
        #expect(Calculator.evaluate("10 % 4") == 2)
        #expect(Calculator.evaluate("-5") == nil, "a number alone isn't a sum")
        #expect(Calculator.evaluate("1/0") == nil)
        #expect(Calculator.evaluate("spotify") == nil)
        #expect(Calculator.evaluate("2+") == nil)
        #expect(Calculator.evaluate("1e10+1") == nil, "only digits and operators")
        #expect(Calculator.format(54) == "54")
        #expect(Calculator.format(1.0 / 3).hasPrefix("0.3333"))
    }

    @Test func timesPeopleSay() throws {
        let cal = Calendar.current
        let now = try #require(cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()))
        let six = try #require(LocalDates.parse("at 6", now: now))
        #expect(cal.component(.hour, from: six.date) == 18 && six.hasTime, "at 6 means the evening")
        let morning = try #require(LocalDates.parse("at 7:30 am", now: now))
        #expect(cal.component(.hour, from: morning.date) == 7 && cal.component(.minute, from: morning.date) == 30)
        #expect(!cal.isDate(morning.date, inSameDayAs: now), "already past today: tomorrow")
        let tomorrow = try #require(LocalDates.parse("tomorrow", now: now))
        #expect(!tomorrow.hasTime, "a day without a time")
        let lunch = try #require(LocalDates.parse("tomorrow at 1pm", now: now))
        #expect(lunch.hasTime && cal.component(.hour, from: lunch.date) == 13)
        let soon = try #require(LocalDates.parse("in 20 minutes", now: now))
        #expect(soon.date.timeIntervalSince(now) == 20 * 60)
        #expect(LocalDates.parse("call mum", now: now) == nil)
    }

    @Test func quickCommandsNeedNoModel() {
        #expect(LocalCommands.quick("volume 30")?.level == 30)
        #expect(LocalCommands.quick("set the volume to 75%")?.level == 75)
        #expect(LocalCommands.quick("mute")?.level == 0)
        #expect(LocalCommands.quick("dark mode")?.mode == "dark")
        #expect(LocalCommands.quick("dark mode off")?.mode == "light")
        #expect(LocalCommands.quick("volume 300") == nil)
        #expect(LocalCommands.quick("darkroom") == nil)
        #expect(LocalCommands.quick("what's on tomorrow")?.action == .showCalendar)
        #expect(LocalCommands.quick("what's on my calendar today")?.action == .showCalendar)
        #expect(LocalCommands.quick("do I have anything on friday")?.action == .showCalendar)
        #expect(LocalCommands.quick("show my reminders")?.action == .showReminders)
        #expect(LocalCommands.quick("what's on netflix") == nil, "not your calendar")
    }

    @Test func commandsQuestionsAndSearchesAreToldApart() {
        #expect(LocalCommands.looksLikeCommand("add lunch with Enda tomorrow at 1"))
        #expect(LocalCommands.looksLikeCommand("remind me to call mum at 6"))
        #expect(!LocalCommands.looksLikeCommand("spotify"))
        #expect(!LocalCommands.looksLikeCommand("what's the capital of France?"))
        #expect(LocalCommands.looksLikeQuestion("why is the sky blue"))
        #expect(!LocalCommands.looksLikeQuestion("project report.pdf"))
    }

    @Test func plansBecomeMacToolCalls() throws {
        var event = LocalPlan(action: .createEvent)
        event.title = "Lunch with Enda"
        #expect(event.missing != nil && event.toolCall == nil, "no time yet")
        let when = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 13)))
        event.when = LocalDates.When(date: when, hasTime: true)
        let call = try #require(event.toolCall)
        #expect(call.name == "calendar_create_event")
        #expect(call.args["start"]?.string == "2026-11-19T13:00")
        #expect(event.needsConfirmation)

        var reminder = LocalPlan(action: .createReminder)
        reminder.title = "Call mum"
        reminder.when = LocalDates.When(date: when, hasTime: false)
        #expect(reminder.toolCall?.args["due"]?.string == "2026-11-19", "a day, no time")

        var volume = LocalPlan(action: .setVolume)
        volume.level = 140
        #expect(volume.toolCall?.args["level"]?.int == 100)
        #expect(!volume.needsConfirmation)
        #expect(LocalPlan(action: .quitApp, app: "Safari").needsConfirmation)
    }

    @Test func theModelsChoiceMustFitTheWords() {
        #expect(LocalCommands.fits(.openApp, "open spotify"))
        #expect(!LocalCommands.fits(.openApp, "what's the capital of France"))
        #expect(!LocalCommands.fits(.createNote, "write a poem about rain"))
        #expect(LocalCommands.fits(.createNote, "note that the wifi password changed"))
        #expect(!LocalCommands.fits(.runShortcut, "how do I centre a div"))
        #expect(LocalCommands.fits(.showCalendar, "what's on tomorrow"))
    }

    @Test func appNamesMatchLikeSpotlight() {
        #expect(NameMatch.score("Spotify", "spotify") == 100)
        #expect(NameMatch.score("Spotify", "spot") > NameMatch.score("Spotify", "tify"))
        #expect(NameMatch.score("Visual Studio Code", "vsc") > 0, "initials")
        #expect(NameMatch.score("Visual Studio Code", "studio") > 0, "a later word")
        #expect(NameMatch.score("Safari", "chrome") == 0)
        #expect(SettingsPanes.matches("wifi").first?.0.name == "Wi-Fi")
        #expect(SettingsPanes.matches("dock").first?.0.name == "Desktop & Dock")
    }

    @Test func webAddressesAndSearches() {
        #expect(WebTarget.url(from: "example.com")?.absoluteString == "https://example.com")
        #expect(WebTarget.url(from: "https://x.example/a?b=1")?.host() == "x.example")
        #expect(WebTarget.url(from: "lunch tomorrow") == nil)
        #expect(WebTarget.url(from: "report.pdf") == nil, "a file name, not a site")
        #expect(WebTarget.search("swift testing")?.absoluteString.contains("q=swift%20testing") == true)
    }
}

/// The real on-device model (Apple Intelligence). Off unless AGENTX_LIVE_MODEL=1, since it
/// needs Apple Intelligence turned on and takes a few seconds.
@Suite("Apple Intelligence, live", .enabled(if: ProcessInfo.processInfo.environment["AGENTX_LIVE_MODEL"] != nil))
@MainActor
struct LiveLocalModelTests {
    @Test func commandsBecomePlans() async throws {
        let local = LocalCommands.shared
        try #require(local.isAvailable, "Apple Intelligence isn't available: \(local.availability.message)")
        let lunch = try await local.plan("add lunch with Enda tomorrow at 1pm")
        #expect(lunch.action == .createEvent)
        #expect(lunch.title.localizedCaseInsensitiveContains("lunch"))
        #expect(lunch.when?.hasTime == true && Calendar.current.component(.hour, from: lunch.when!.date) == 13)
        let mum = try await local.plan("remind me to call mum at 6")
        #expect(mum.action == .createReminder && mum.title.localizedCaseInsensitiveContains("mum"))
        #expect(Calendar.current.component(.hour, from: mum.when?.date ?? .distantPast) == 18)
        #expect(try await local.plan("open spotify").action == .openApp)
        #expect(LocalCommands.quick("what's on my calendar tomorrow")?.action == .showCalendar, "known without the model")
        for question in ["what's the capital of France", "write a poem about rain", "how do I centre a div"] {
            let plan = try await local.plan(question)
            #expect(plan.action == .none, "\(question) → \(plan.action) \(plan.title)")
        }
    }
}

@Suite("File results")
struct FileResultTests {
    @Test func buildLeftoversAreSkipped() {
        let home = NSHomeDirectory()
        #expect(FileSearch.isNoise(home + "/Projects/news/node_modules/lucide-react/dist/esm/icons/spotlight.mjs"))
        #expect(FileSearch.isNoise(home + "/Projects/AgentX/build/DerivedData/SDKExplicitPrecompiledModules/CoreSpotlight.pcm"))
        #expect(FileSearch.isNoise(home + "/Library/Caches/x.txt"))
        #expect(!FileSearch.isNoise(home + "/Documents/Spotify invoice.pdf"))
    }
}

@Suite("Apps")
@MainActor
struct AppIndexTests {
    @Test func findsInstalledApps() async throws {
        AppIndex.shared.refreshIfNeeded()
        for _ in 0..<40 where AppIndex.shared.apps.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(AppIndex.shared.apps.count > 10, "\(AppIndex.shared.apps.count) apps")
        #expect(AppIndex.shared.matches("saf").first?.0.name == "Safari")
        #expect(AppIndex.shared.matches("finder").first?.0.name == "Finder")
    }
}

@Suite("One clear result")
@MainActor
struct OneResultTests {
    func ready() async throws {
        AppIndex.shared.refreshIfNeeded()
        for _ in 0..<40 where AppIndex.shared.apps.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func openingAnAppShowsJustThatApp() async throws {
        try await ready()
        let rows = LauncherController.shared.buildResults("open safari", files: [])
        #expect(rows.count == 1 && rows.first?.title == "Safari" && rows.first?.verb == "Open")
        let named = LauncherController.shared.buildResults("safari", files: [])
        #expect(named.count == 1 && named.first?.title == "Safari", "a name typed in full is the one")
    }

    @Test func noEngineNamesAndOneAnswerForQuestions() async throws {
        try await ready()
        let rows = LauncherController.shared.buildResults("why is the sky blue", files: [])
        #expect(rows.count == 1 && rows.first?.title == "why is the sky blue" && rows.first?.verb == "Ask")
        for text in ["why is the sky blue", "add lunch with Enda tomorrow at 1", "spot", "open safari"] {
            for row in LauncherController.shared.buildResults(text, files: []) {
                #expect(!row.title.contains("Claude") && !row.title.contains("Apple Intelligence") && !(row.subtitle ?? "").contains("Apple Intelligence"))
            }
        }
        #expect(LauncherController.shared.buildResults("volume 30", files: []).count == 1)
        #expect(LauncherController.shared.buildResults("12*4", files: []).first?.title == "= 48")
    }
}

@Suite("More on this Mac")
struct MoreLocalTests {
    @Test func translationGoesToYourLanguageOrEnglish() {
        #expect(LocalWriter.detectLanguage("Bonjour, comment allez-vous aujourd'hui ?") == "fr")
        #expect(LocalWriter.defaultTarget(for: "Bonjour, comment allez-vous aujourd'hui ?", userLanguage: "en") == "en")
        #expect(LocalWriter.defaultTarget(for: "Thanks for the update, see you tomorrow.", userLanguage: "en") == nil, "already yours: pick one")
        #expect(LocalWriter.defaultTarget(for: "Thanks for the update, see you tomorrow.", userLanguage: "hi") == "hi")
    }

    @Test func titlesAreCleanedUp() {
        #expect(LocalTitles.clean("\"Friday afternoon plans.\"") == "Friday afternoon plans")
        #expect(LocalTitles.clean("Title: Lunch with Enda") == "Lunch with Enda")
        #expect(LocalTitles.clean("") == nil)
        #expect(LocalTitles.clean("line one\nline two") == nil)
    }

    @Test func periodsForFiles() throws {
        let cal = Calendar.current
        let now = Date()
        let week = try #require(LocalDates.since("the PDFs I downloaded this week", now: now))
        #expect(week == cal.dateInterval(of: .weekOfYear, for: now)?.start)
        let three = try #require(LocalDates.since("past 3 days", now: now))
        #expect(three == cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: now)))
        #expect(LocalDates.since("my tax return") == nil)
    }

    @Test func pointingIsKnownWithoutTheModel() {
        #expect(LocalCommands.quick("where's the share button")?.target == "share")
        #expect(LocalCommands.quick("point to export")?.target == "export")
        #expect(LocalCommands.quick("show me where the sign in link is")?.target == "sign in")
        #expect(LocalCommands.quick("where is paris") == nil, "a question, not the screen")
    }

    @Test func newCommandsMustFitTheWords() {
        #expect(LocalCommands.fits(.findFiles, "find the pdfs i downloaded this week"))
        #expect(LocalCommands.fits(.draftEmail, "email enda saying i'll be late"))
        #expect(LocalCommands.fits(.sendMessage, "text mum i'm on my way"))
        #expect(!LocalCommands.fits(.sendMessage, "what's the capital of france"))
        #expect(LocalCommands.looksLikeCommand("email enda saying i'll be late"))
        #expect(LocalCommands.looksLikeCommand("find the pdfs i downloaded this week"))
    }

    @Test func theDayIsDescribedPlainly() {
        let start = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!
        let agenda = Agenda(start: start, end: start, events: [.init(id: "1", title: "Lunch with Enda", start: start, end: start.addingTimeInterval(3600),
                                                                     isAllDay: false, calendar: "Home", color: nil, location: nil)])
        #expect(TodayAgenda.describe(agenda).hasSuffix("Lunch with Enda"))
    }
}

/// The real on-device model and Translation. Off unless AGENTX_LIVE_MODEL=1.
@Suite("Apple Intelligence writing, live", .enabled(if: ProcessInfo.processInfo.environment["AGENTX_LIVE_MODEL"] != nil))
@MainActor
struct LiveLocalWritingTests {
    @Test func writesTranslatesAndTitles() async throws {
        try #require(LocalCommands.shared.isAvailable)
        let text = "Hi team, the launch moves from Thursday to Monday because the payment provider needs two more days for review. Marketing emails go out Monday morning; support should expect questions about the delay."
        let summary = try await LocalWriter.run(.summarize, text: text)
        #expect(summary.localizedCaseInsensitiveContains("monday"))
        let fixed = try await LocalWriter.run(.fix, text: "i has went to the shop yesterday and buyed milk")
        #expect(!fixed.isEmpty && !fixed.contains("buyed"))
        let answer = try await LocalWriter.run(.ask, text: text, question: "why is the launch moving?")
        #expect(answer.localizedCaseInsensitiveContains("payment") || answer.localizedCaseInsensitiveContains("review"))
        let spanish = try await LocalWriter.translate("Good morning, see you at lunch.", to: "es")
        #expect(spanish.localizedCaseInsensitiveContains("buenos") || spanish.localizedCaseInsensitiveContains("almuerzo"))
        let title = try #require(await LocalTitles.title(for: "Can you check whether I have anything on Friday afternoon?"))
        #expect(title.split(separator: " ").count <= 7)
    }

    @Test func newCommands() async throws {
        let local = LocalCommands.shared
        try #require(local.isAvailable)
        let pdfs = try await local.plan("find the PDFs I downloaded this week")
        #expect(pdfs.action == .findFiles && pdfs.fileKind == "pdf" && pdfs.since != nil)
        let email = try await local.plan("email Enda saying I'll be 10 minutes late")
        #expect(email.action == .draftEmail && email.recipient?.localizedCaseInsensitiveContains("enda") == true)
        #expect(email.message?.localizedCaseInsensitiveContains("late") == true)
        let text = try await local.plan("text mum I'm on my way")
        #expect(text.action == .sendMessage && text.message?.localizedCaseInsensitiveContains("way") == true)
        let event = try await local.plan("add this to my calendar", about: "Dinner with Ana on Friday at 7pm at Luigi's")
        #expect(event.action == .createEvent && event.title.localizedCaseInsensitiveContains("dinner"))
        #expect(Calendar.current.component(.hour, from: event.when?.date ?? .distantPast) == 19)
    }
}

@Suite("Finding files")
@MainActor
struct FindFilesTests {
    @Test func findsWithoutHanging() async {
        let start = Date()
        _ = await FileSearch.find(kind: "pdf", words: nil, since: LocalDates.since("this month"), folder: "downloads")
        // One condition alone (Spotlight throws on a compound with a single part).
        _ = await FileSearch.find(kind: "pdf", words: nil, since: nil, folder: "downloads")
        _ = await FileSearch.find(kind: "screenshot", words: "invoice", since: nil, folder: nil)
        #expect(Date().timeIntervalSince(start) < 20, "always answers, even if Spotlight is slow")
    }
}

@Suite("File searches in plain words")
struct FileQueryTests {
    @Test func understoodWithoutTheModel() throws {
        let latest = try #require(LocalCommands.fileQuery("latest PDF in downloads"))
        #expect(latest.fileKind == "pdf" && latest.folder == "downloads" && latest.target == nil)
        let shots = try #require(LocalCommands.fileQuery("screenshots from today"))
        #expect(shots.fileKind == "screenshot" && shots.since != nil)
        let invoice = try #require(LocalCommands.fileQuery("invoice pdf"))
        #expect(invoice.fileKind == "pdf" && invoice.target == "invoice")
        let sheets = try #require(LocalCommands.fileQuery("find the spreadsheets I downloaded this week"))
        #expect(sheets.fileKind == "spreadsheet" && sheets.folder == "downloads" && sheets.since != nil)
        #expect(LocalCommands.fileQuery("files on my desktop")?.folder == "desktop")
    }

    @Test func otherThingsArentFileSearches() {
        #expect(LocalCommands.fileQuery("summarize the latest pdf") == nil, "doing something with a file")
        #expect(LocalCommands.fileQuery("what's the capital of France") == nil)
        #expect(LocalCommands.fileQuery("open safari") == nil)
    }
}

@Suite("Apps before files")
@MainActor
struct AppsBeforeFilesTests {
    @Test func anAppsNameOpensTheApp() async throws {
        AppIndex.shared.refreshIfNeeded()
        for _ in 0..<40 where AppIndex.shared.apps.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        #expect(LauncherController.shared.fileSearch(for: "photos") == nil, "the Photos app")
        #expect(LauncherController.shared.buildResults("photos", files: []).first?.title == "Photos")
        #expect(LauncherController.shared.fileSearch(for: "latest PDF in downloads") != nil)
    }
}

@Suite("Spotlight queries")
struct SpotlightQueryTests {
    /// Spotlight throws an Objective-C exception on an AND/OR with fewer than two parts,
    /// which Swift can't catch: it left the app broken and it crashed seconds later.
    func wellFormed(_ p: NSPredicate) -> Bool {
        guard let c = p as? NSCompoundPredicate else { return true }
        if c.compoundPredicateType != .not, c.subpredicates.count < 2 { return false }
        return c.subpredicates.allSatisfy { wellFormed($0 as! NSPredicate) }
    }

    @Test func everyShapeIsOneSpotlightAccepts() {
        for kind in [nil, "any", "pdf", "screenshot", "image", "video", "audio", "spreadsheet", "presentation", "document"] {
            for words in [nil, "", "invoice", "tax*return?"] {
                for since in [nil, Date()] {
                    let p = FileSearch.predicate(kind: kind, words: words, since: since)
                    #expect(wellFormed(p), "\(kind ?? "nil") \(words ?? "nil") \(since == nil ? "-" : "since"): \(p)")
                }
            }
        }
    }
}

@Suite("Protected folders")
struct FolderAccessTests {
    @Test func searchesKnowWhichFolderTheyNeed() throws {
        let shots = try #require(LocalCommands.fileQuery("screenshots from this week"))
        #expect(FolderAccess.folder(for: shots) == FolderAccess.screenshotFolder)
        let downloads = try #require(LocalCommands.fileQuery("latest PDF in downloads"))
        #expect(FolderAccess.folder(for: downloads)?.lastPathComponent == "Downloads")
        let anywhere = try #require(LocalCommands.fileQuery("invoice pdf"))
        #expect(FolderAccess.folder(for: anywhere) == nil, "no folder named: no prompt")
    }
}
