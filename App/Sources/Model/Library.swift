import Engine
import Foundation
import Observation

/// A grade as the user typed it: `value` out of `outOf`, not necessarily the leaf's own scale —
/// e.g. a teacher grades out of 2 while the model's leaf is out of 10. A percentage is stored out
/// of 100 and a letter as its value out of 10, with `letter` kept to show it back.
struct GradeEntry: Codable, Equatable {
    var value: Double
    var outOf: Double
    var letter: String?
}

/// The two exam sittings of an academic year.
enum Convocatoria: String, CaseIterable, Identifiable, Codable {
    case ordinary, extraordinary

    var id: Self { self }

    var label: String {
        switch self {
        case .ordinary: "Ordinaria"
        case .extraordinary: "Extraordinaria"
        }
    }
}

/// One subject in a course: its (editable) evaluation tree plus the grades entered for it, keyed
/// by leaf name, for each sitting.
///
/// The extraordinary sitting reuses the same tree unless it has its own (`extraordinaryRoot`). A
/// part carries its ordinary grade over as its "En la extraordinaria" rule says: by default
/// everything does except the final exam, which is retaken and starts empty.
struct SubjectRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var subject: Subject
    var entries: [String: GradeEntry]
    var extraordinaryEntries: [String: GradeEntry]
    var ordinaryExamDate: Date?
    var extraordinaryExamDate: Date?
    /// The degree-wide term (cuatrimestre) it's taught in — 3 is the first term of the second
    /// year. `nil` for a year-long subject. The UI shows it relative to the year (see `Period`).
    var term: Int?
    /// A year-long subject graded separately in each of its year's terms: its root is the general
    /// evaluation, with one child per term holding that term's own (see `SubjectEditorView`). It
    /// shows in every term on the home screen.
    var isPerTerm = false
    /// Tile customisation: an SF Symbol name and a `SubjectColor` raw value. `nil` falls back to
    /// ones derived from the subject (see `SubjectStyle`).
    var symbol: String?
    var colorName: String?
    /// The extraordinary sitting's own evaluation, when the guide weighs it differently (the exam
    /// worth 100 %, say). `nil` reuses the ordinary one. A note with the same name in both is the
    /// same note.
    var extraordinaryRoot: Node?
    /// "No presentado" in each sitting: no grade, not a fail, out of the averages.
    var ordinaryNotPresented = false
    var extraordinaryNotPresented = false
    /// "Matrícula de honor" on the final grade.
    var hasHonors = false
    /// Conditions with no grade, like compulsory attendance: one not met fails the subject.
    var requirements: [SubjectRequirement] = []

    init(id: UUID = UUID(), subject: Subject, entries: [String: GradeEntry] = [:], term: Int? = nil) {
        self.id = id
        self.subject = subject
        self.entries = entries
        self.extraordinaryEntries = [:]
        self.term = term
    }

    /// Fields added after the first release decode as empty, so older libraries keep loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subject = try container.decode(Subject.self, forKey: .subject)
        entries = try container.decodeIfPresent([String: GradeEntry].self, forKey: .entries) ?? [:]
        extraordinaryEntries = try container.decodeIfPresent([String: GradeEntry].self, forKey: .extraordinaryEntries) ?? [:]
        ordinaryExamDate = try container.decodeIfPresent(Date.self, forKey: .ordinaryExamDate)
        extraordinaryExamDate = try container.decodeIfPresent(Date.self, forKey: .extraordinaryExamDate)
        term = try container.decodeIfPresent(Int.self, forKey: .term)
        isPerTerm = try container.decodeIfPresent(Bool.self, forKey: .isPerTerm) ?? false
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        colorName = try container.decodeIfPresent(String.self, forKey: .colorName)
        extraordinaryRoot = try container.decodeIfPresent(Node.self, forKey: .extraordinaryRoot)
        ordinaryNotPresented = try container.decodeIfPresent(Bool.self, forKey: .ordinaryNotPresented) ?? false
        extraordinaryNotPresented = try container.decodeIfPresent(Bool.self, forKey: .extraordinaryNotPresented) ?? false
        hasHonors = try container.decodeIfPresent(Bool.self, forKey: .hasHonors) ?? false
        requirements = try container.decodeIfPresent([SubjectRequirement].self, forKey: .requirements) ?? []
    }

    func isNotPresented(in session: Convocatoria) -> Bool {
        session == .ordinary ? ordinaryNotPresented : extraordinaryNotPresented
    }

    /// Whether a requirement is marked as not met.
    var missesARequirement: Bool { requirements.contains { $0.isMet == false } }

    /// Evaluated with continuous or single-exam schemes.
    var hasSchemes: Bool {
        if case .alternatives = subject.root { true } else { false }
    }

    /// Evaluated as "Nota única": just its final grade, with no sittings or dates.
    var isSingleGrade: Bool { subject.root.asGrade != nil }

    /// Evaluated as "Por definir": its notes are only listed by section, with no final grade.
    var isUndecided: Bool { subject.root.asGroup?.combination == .undecided }

    /// The sitting worth showing by default: the extraordinary one once anything's been entered
    /// there. A single-grade subject has only one.
    var activeSession: Convocatoria {
        if isSingleGrade { return .ordinary }
        return extraordinaryEntries.isEmpty && !extraordinaryNotPresented ? .ordinary : .extraordinary
    }

    func examDate(for session: Convocatoria) -> Date? {
        switch session {
        case .ordinary: ordinaryExamDate
        case .extraordinary: extraordinaryExamDate
        }
    }

    /// The exam's date lives here, one per sitting. A final-exam grade with a date of its own (set
    /// before it was marked as the exam, or from an older version) hands it to the ordinary sitting
    /// when that has none, so the exam never shows two different dates.
    mutating func moveExamGradeDates() {
        let dates = subject.root.grades.filter { $0.isFinalExam == true }.compactMap(\.date)
        guard !dates.isEmpty else { return }
        if ordinaryExamDate == nil { ordinaryExamDate = dates.min() }
        subject.root.updateGrades { if $0.isFinalExam == true { $0.date = nil } }
    }

    /// Whether this leaf's ordinary grade carries over to the extraordinary sitting: for now
    /// everything but the final exam does (`Grade.recovery` isn't asked for in the editor yet),
    /// except a section that missed a minimum sending it to the extraordinary — that one is
    /// taken again.
    func keepsForExtraordinary(_ leaf: String) -> Bool {
        let root = subject.root
        guard let grade = root.leaf(named: leaf)?.asGrade else { return false }
        let inputs = SubjectProgress.inputs(self, session: .ordinary)
        if root.leavesSentToExtraordinary(inputs).contains(leaf) { return false }
        guard let (recovery, node) = root.recoveryRule(for: leaf) else { return grade.isFinalExam != true }
        switch recovery {
        case .recoverableInExtraordinary: return false
        case .notRecoverable, .savedForExtraordinary, .savedForNextYear, .partiallyRecoverableInFinal: return true
        case .savedIfAtLeast(let threshold): return node.evaluate(inputs, pendingFraction: 0) >= threshold - 1e-9
        }
    }

    /// A note that can't be taken again: in the extraordinary it shows the ordinary grade, fixed.
    func isLockedInExtraordinary(_ leaf: String) -> Bool {
        subject.root.recoveryRule(for: leaf)?.recovery == .notRecoverable && keepsForExtraordinary(leaf)
    }

    /// After an edit: moves each stored grade to its note, found by the id it had when the editor
    /// opened (`openingIDs`, by the name it had then), under whatever name it has now. A copied
    /// section repeats its notes' ids and the first copy keeps them, with their grades; grades of
    /// notes that are gone are dropped.
    ///
    /// The extraordinary sitting's grades follow its own tree when it has one, by the ids it had
    /// when the editor opened (`openingExtraordinaryIDs`); a tree made during the edit is a copy of
    /// the ordinary one, ids included, so they follow `openingIDs` into it.
    mutating func reassignGrades(openingIDs: [String: UUID], openingExtraordinaryIDs: [String: UUID] = [:]) {
        subject.root.identifyGrades()
        extraordinaryRoot?.identifyGrades()
        func moved(_ entries: [String: GradeEntry], in root: Node, from ids: [String: UUID]) -> [String: GradeEntry] {
            let names = root.gradeNamesByID
            let otherLeaves = Set(root.allLeafNames()).subtracting(root.grades.map(\.name))
            var moved: [String: GradeEntry] = [:]
            // Leaves that aren't notes (a bonus) have no id and keep their name.
            for (name, entry) in entries where otherLeaves.contains(name) {
                moved[name] = entry
            }
            for (name, entry) in entries {
                if let id = ids[name], let new = names[id] { moved[new] = entry }
            }
            return moved
        }
        entries = moved(entries, in: subject.root, from: openingIDs)
        extraordinaryEntries = moved(
            extraordinaryEntries,
            in: extraordinaryRoot ?? subject.root,
            from: extraordinaryRoot != nil && !openingExtraordinaryIDs.isEmpty ? openingExtraordinaryIDs : openingIDs
        )
    }

    /// The tree a sitting is worked out with: the extraordinary one drops the minimums that only
    /// sent you there.
    func root(for session: Convocatoria) -> Node {
        session == .extraordinary ? (extraordinaryRoot ?? subject.root).forExtraordinary : subject.root
    }

    func entry(for leaf: String, in session: Convocatoria) -> GradeEntry? {
        switch session {
        case .ordinary:
            entries[leaf]
        case .extraordinary:
            extraordinaryEntries[leaf] ?? (keepsForExtraordinary(leaf) ? entries[leaf] : nil)
        }
    }

    /// True when the extraordinary sitting is showing a grade carried over from the ordinary one.
    func isCarriedOver(_ leaf: String, in session: Convocatoria) -> Bool {
        session == .extraordinary && extraordinaryEntries[leaf] == nil && keepsForExtraordinary(leaf) && entries[leaf] != nil
    }

    func entries(for session: Convocatoria) -> [String: GradeEntry] {
        let leaves = root(for: session).allLeafNames()
        // Not `uniqueKeysWithValues`: a tree from an old or hand-edited file can repeat a leaf name.
        return Dictionary(leaves.compactMap { leaf in entry(for: leaf, in: session).map { (leaf, $0) } }) { first, _ in first }
    }
}

/// One year of the degree and the subjects taken in it.
struct Course: Identifiable, Codable, Equatable {
    var id = UUID()
    var year: Int
    var subjects: [SubjectRecord]

    func name(in degree: DegreeSettings) -> String { degree.yearLabel(year) }

    init(id: UUID = UUID(), year: Int, subjects: [SubjectRecord] = []) {
        self.id = id
        self.year = year
        self.subjects = subjects
    }

    private enum CodingKeys: String, CodingKey { case id, year, name, subjects }

    /// Older libraries stored only a name like "2.º curso": the year is the number in it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        subjects = try container.decode([SubjectRecord].self, forKey: .subjects)
        if let year = try container.decodeIfPresent(Int.self, forKey: .year) {
            self.year = year
        } else {
            let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            year = Int(name.filter(\.isNumber)) ?? 1
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(year, forKey: .year)
        try container.encode(subjects, forKey: .subjects)
    }
}

/// Every course, subject and grade, persisted as one JSON file in Application Support. A stopgap
/// ahead of the brief's SwiftData model (§6); every mutation goes through a method here so there's
/// exactly one place that saves.
@MainActor
@Observable
final class Library {
    private(set) var courses: [Course] = []
    private(set) var degree = DegreeSettings()
    /// `false` once the current study has been archived and no other created yet: Cuenta offers to
    /// create one, and so does adding a subject. A fresh install starts with one (a university
    /// degree), ready to fill.
    private(set) var hasStudy = true
    /// Home-screen views made by hand from any subjects (see `CustomSelection`).
    private(set) var selections: [CustomSelection] = []
    /// `nil` for a simulation: it lives only in memory and never touches the real library.
    @ObservationIgnored private let fileURL: URL?
    /// Studies put away to start another, newest last.
    private(set) var archives: [ArchivedStudy] = []
    /// Subjects that have a teaching guide (PDF) stored next to the library file.
    private(set) var guideIDs: Set<SubjectRecord.ID> = []
    /// The file is there but couldn't be read at all — iOS keeps it locked until the phone is
    /// first unlocked after a restart, and can launch the app before that. Nothing is saved over
    /// it until `reloadIfNeeded()` manages to read it.
    @ObservationIgnored private var isWaitingForFile = false

    private struct Snapshot: Codable {
        var courses: [Course]
        var degree: DegreeSettings?
        var selections: [CustomSelection]?
        var archives: [ArchivedStudy]?
        var hasStudy: Bool?
    }

    /// Both allow NaN and infinity, so a stray non-number can never make every later save fail.
    nonisolated static var fileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    nonisolated static var fileDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "library.json")) {
        self.fileURL = fileURL
        load()
        let files = (try? FileManager.default.contentsOfDirectory(at: guidesDirectory, includingPropertiesForKeys: nil)) ?? []
        guideIDs = Set(files.filter { $0.pathExtension == "pdf" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        save()
    }

    /// Reads the file again if it couldn't be read at launch; call it when the app comes forward.
    func reloadIfNeeded() {
        guard isWaitingForFile else { return }
        load()
        if !isWaitingForFile { save() }
    }

    private func load() {
        guard let fileURL else { return }
        let data = try? Data(contentsOf: fileURL)
        isWaitingForFile = data == nil && FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
        if let data, let snapshot = try? Self.fileDecoder.decode(Snapshot.self, from: data) {
            courses = snapshot.courses
            degree = snapshot.degree ?? DegreeSettings()
            selections = snapshot.selections ?? []
            archives = snapshot.archives ?? []
            hasStudy = snapshot.hasStudy ?? true
        } else if let data, let courses = try? Self.fileDecoder.decode([Course].self, from: data) {
            // The first file format was a bare list of courses.
            self.courses = courses
        } else {
            courses = []
            // A file that's there but can't be read is kept aside instead of being overwritten by
            // the empty library below, so a bad update never silently wipes someone's grades.
            if data != nil {
                let aside = fileURL.deletingLastPathComponent()
                    .appending(path: "library-unreadable-\(Int(Date.now.timeIntervalSince1970)).json")
                // And if even that fails, it's left alone rather than saved over.
                if (try? FileManager.default.copyItem(at: fileURL, to: aside)) == nil { isWaitingForFile = true }
            }
        }
        normalize()
    }

    /// A throwaway library holding a copy of one subject with its current grades, for the
    /// simulator: edit anything, nothing is saved, and it disappears when the simulator closes.
    init(simulating record: SubjectRecord, degree: DegreeSettings) {
        fileURL = nil
        self.degree = degree
        courses = [Course(year: 1, subjects: [record])]
    }

    /// An empty study that lives only in memory, for the guided tour: nothing done in it is saved.
    init(inMemory degree: DegreeSettings) {
        fileURL = nil
        self.degree = degree
        courses = []
    }

    /// Exam dates spread over the coming weeks on the first few subjects, so a tour's calendar has
    /// something to show.
    func addSampleDates() {
        var day = 3
        for course in courses.indices {
            for index in courses[course].subjects.indices where day < 30 {
                courses[course].subjects[index].ordinaryExamDate = Calendar.current.date(byAdding: .day, value: day, to: .now)
                day += 5
            }
        }
        save()
    }

    /// Makes whatever was loaded safe to show: one course per year (from the 1st), no subject id used twice, and
    /// the final exam flagged on old subjects. Runs after loading the file and after a restore.
    private func normalize() {
        var merged: [Course] = []
        for var course in courses {
            course.year = max(course.year, 1)
            if let index = merged.firstIndex(where: { $0.year == course.year }) {
                merged[index].subjects += course.subjects
            } else {
                merged.append(course)
            }
        }
        var seen: Set<SubjectRecord.ID> = []
        for course in merged.indices {
            for index in merged[course].subjects.indices {
                if !seen.insert(merged[course].subjects[index].id).inserted {
                    merged[course].subjects[index].id = UUID()
                    seen.insert(merged[course].subjects[index].id)
                }
                // Terms count from 1; anything else is treated as year-long.
                if let term = merged[course].subjects[index].term, term < 1 { merged[course].subjects[index].term = nil }
            }
        }
        courses = merged.sorted { $0.year < $1.year }
        flagFinalExams()
    }

    // MARK: Teaching guides

    private var guidesDirectory: URL { (fileURL ?? URL.temporaryDirectory).deletingLastPathComponent().appending(path: "Guides") }

    /// The stored guide PDF for a subject, if it has one.
    func guideURL(for id: SubjectRecord.ID) -> URL? {
        guideIDs.contains(id) ? guidesDirectory.appending(path: "\(id.uuidString).pdf") : nil
    }

    func setGuide(_ data: Data, for id: SubjectRecord.ID) throws {
        try FileManager.default.createDirectory(at: guidesDirectory, withIntermediateDirectories: true)
        try data.write(to: guidesDirectory.appending(path: "\(id.uuidString).pdf"), options: .atomic)
        guideIDs.insert(id)
    }

    func removeGuide(for id: SubjectRecord.ID) {
        try? FileManager.default.removeItem(at: guidesDirectory.appending(path: "\(id.uuidString).pdf"))
        guideIDs.remove(id)
    }

    /// The stored guides of these subjects, by subject, for the backup file.
    private func guides(for ids: Set<SubjectRecord.ID>) -> [String: Data] {
        var result: [String: Data] = [:]
        for id in guideIDs.intersection(ids) {
            if let url = guideURL(for: id), let data = try? Data(contentsOf: url) { result[id.uuidString] = data }
        }
        return result
    }

    /// Subjects saved before the final exam had its own marker get it on the leaves named like one,
    /// once, so they show the exam card too.
    private func flagFinalExams() {
        let names: Set<String> = ["Prueba objetiva", "Examen final", "Prueba mixta", "Examen", "Examen de teoría", "Examen de prácticas"]
        for course in courses.indices {
            for index in courses[course].subjects.indices {
                // A single-grade subject is its final grade, not an exam with sittings (it was
                // marked as one when "Nota única" first came in).
                if case .grade(var grade) = courses[course].subjects[index].subject.root, grade.isFinalExam != nil {
                    grade.isFinalExam = nil
                    courses[course].subjects[index].subject.root = .grade(grade)
                    continue
                }
                var root = courses[course].subjects[index].subject.root
                guard !root.grades.contains(where: { $0.isFinalExam == true }) else { continue }
                root.updateGrades { if names.contains($0.name) { $0.isFinalExam = true } }
                courses[course].subjects[index].subject.root = root
            }
        }
        for course in courses.indices {
            for index in courses[course].subjects.indices { courses[course].subjects[index].moveExamGradeDates() }
        }
    }

    func record(id: SubjectRecord.ID) -> SubjectRecord? {
        courses.lazy.flatMap(\.subjects).first { $0.id == id }
    }

    func setEntry(_ entry: GradeEntry?, forLeaf leaf: String, in recordID: SubjectRecord.ID, session: Convocatoria) {
        if let entry, !(entry.value.isFinite && entry.outOf.isFinite && entry.outOf > 0) { return }
        mutateRecord(recordID) { record in
            switch session {
            case .ordinary: record.entries[leaf] = entry
            case .extraordinary: record.extraordinaryEntries[leaf] = entry
            }
        }
    }

    func setExamDate(_ date: Date?, for session: Convocatoria, in recordID: SubjectRecord.ID) {
        mutateRecord(recordID) { record in
            switch session {
            case .ordinary: record.ordinaryExamDate = date
            case .extraordinary: record.extraordinaryExamDate = date
            }
        }
    }

    func setGradeDate(_ date: Date?, forLeaf leaf: String, in recordID: SubjectRecord.ID) {
        mutateRecord(recordID) { $0.subject.root.setDate(date, forLeaf: leaf) }
    }

    func update(_ record: SubjectRecord) {
        mutateRecord(record.id) { $0 = record }
    }

    /// Adds a subject with a single 100 % exam to start from; its evaluation is edited afterwards.
    @discardableResult
    func addSubject(name: String, ects: Double = 6, year: Int, term: Int?) -> SubjectRecord.ID {
        let root = Node.group(Group(name: name, combination: .weightedAverage, children: [
            WeightedChild(weight: 1, node: .grade(Grade(name: "Examen", isFinalExam: true))),
        ]))
        var record = SubjectRecord(subject: Subject(name: name, ectsCredits: ects, root: root), term: term)
        // Bachillerato and ESO: a year-long subject starts with a grade per term.
        if term == nil, degree.studyType.gradesPerTerm, degree.termsPerYear > 1 {
            record.splitByTerm(degree.termLabels)
        }
        hasStudy = true
        courses[courseIndex(forYear: year)].subjects.append(record)
        save()
        return record.id
    }

    func move(_ id: SubjectRecord.ID, toYear year: Int, term: Int?) {
        guard var record = record(id: id) else { return }
        record.term = term
        removeSubject(id)
        courses[courseIndex(forYear: year)].subjects.append(record)
        save()
    }

    func setStyle(symbol: String, colorName: String, for id: SubjectRecord.ID) {
        mutateRecord(id) {
            $0.symbol = symbol
            $0.colorName = colorName
        }
    }

    /// Changing how many terms a year has keeps each subject in the same year and in the same
    /// position within it, clamped to the new count (4th of 4 becomes 2nd of 2).
    func updateDegree(_ new: DegreeSettings) {
        let old = degree
        if new.termsPerYear != old.termsPerYear {
            for course in courses.indices {
                for index in courses[course].subjects.indices {
                    guard let term = courses[course].subjects[index].term else { continue }
                    let relative = min(old.relativeTerm(term), new.termsPerYear)
                    courses[course].subjects[index].term = new.absoluteTerm(year: courses[course].year, relative: relative)
                }
            }
        }
        degree = new
        save()
    }

    /// Adds a ready-made subject (from a template) to a year and term.
    @discardableResult
    func addSubject(_ subject: Subject, year: Int, term: Int?) -> SubjectRecord.ID {
        let record = SubjectRecord(subject: subject, term: term)
        hasStudy = true
        courses[courseIndex(forYear: year)].subjects.append(record)
        save()
        return record.id
    }

    /// Moves `sources` before `target` (or to the end) among `group` — the subjects one grid shows,
    /// in the order it shows them — leaving every other subject of the year where it was.
    func reorderSubjects(_ sources: [SubjectRecord.ID], before target: SubjectRecord.ID?, among group: [SubjectRecord.ID]) {
        guard let course = courses.firstIndex(where: { $0.subjects.contains { group.contains($0.id) } }) else { return }
        let moving = sources.filter(group.contains)
        var ordered = group.filter { !moving.contains($0) }
        ordered.insert(contentsOf: moving, at: target.flatMap(ordered.firstIndex(of:)) ?? ordered.count)

        let slots = courses[course].subjects.indices.filter { group.contains(courses[course].subjects[$0].id) }
        let byID = Dictionary(slots.map { (courses[course].subjects[$0].id, courses[course].subjects[$0]) }) { first, _ in first }
        // Only what really sits in those slots, once each — a stale id (a subject deleted meanwhile)
        // or one from another year must never take a slot or leave one empty.
        var placed: Set<SubjectRecord.ID> = []
        let records = ordered.compactMap { id in placed.insert(id).inserted ? byID[id] : nil }
        guard records.count == slots.count else { return }
        for (slot, record) in zip(slots, records) { courses[course].subjects[slot] = record }
        save()
    }

    func deleteSubject(id: SubjectRecord.ID) {
        removeSubject(id)
        for index in selections.indices { selections[index].subjectIDs.removeAll { $0 == id } }
        if !subjectIDsInUse.contains(id) { removeGuide(for: id) }
        save()
    }

    // MARK: Custom views

    /// Adds the view, or replaces the one with its id.
    func saveSelection(_ selection: CustomSelection) {
        if let index = selections.firstIndex(where: { $0.id == selection.id }) {
            selections[index] = selection
        } else {
            selections.append(selection)
        }
        save()
    }

    func deleteSelection(id: CustomSelection.ID) {
        selections.removeAll { $0.id == id }
        save()
    }

    /// A custom view's subjects in a new order, as dragged on the home screen.
    func reorderSelection(_ id: CustomSelection.ID, to order: [SubjectRecord.ID]) {
        guard let index = selections.firstIndex(where: { $0.id == id }) else { return }
        let current = selections[index].subjectIDs
        guard Set(order) == Set(current), order.count == current.count else { return }
        selections[index].subjectIDs = order
        save()
    }

    /// The year and term a subject is taught in.
    func period(of id: SubjectRecord.ID) -> Period? {
        guard let year = year(of: id) else { return nil }
        return Period(year: year, term: record(id: id)?.term)
    }

    /// The year each subject currently lives in.
    func year(of id: SubjectRecord.ID) -> Int? {
        courses.first { $0.subjects.contains { $0.id == id } }?.year
    }

    private func removeSubject(_ id: SubjectRecord.ID) {
        for course in courses.indices { courses[course].subjects.removeAll { $0.id == id } }
    }

    /// The course for a year, created (in year order) when it doesn't exist yet.
    private func courseIndex(forYear year: Int) -> Int {
        if let index = courses.firstIndex(where: { $0.year == year }) { return index }
        courses.append(Course(year: year))
        courses.sort { $0.year < $1.year }
        return courses.firstIndex { $0.year == year }!
    }

    /// The subjects a scope covers, with their year.
    func records(in scope: DataScope) -> [SubjectRecord] {
        courses.flatMap { course in course.subjects.filter { scope.contains($0, year: course.year) } }
    }

    func clearGrades(in scope: DataScope) {
        for course in courses.indices {
            for subject in courses[course].subjects.indices where scope.contains(courses[course].subjects[subject], year: courses[course].year) {
                courses[course].subjects[subject].entries = [:]
                courses[course].subjects[subject].extraordinaryEntries = [:]
            }
        }
        save()
    }

    func removeSubjects(in scope: DataScope) {
        let ids = Set(records(in: scope).map(\.id))
        for course in courses.indices { courses[course].subjects.removeAll { ids.contains($0.id) } }
        for index in selections.indices { selections[index].subjectIDs.removeAll { ids.contains($0) } }
        selections.removeAll { $0.subjectIDs.isEmpty }
        for id in guideIDs.intersection(ids).subtracting(subjectIDsInUse) { removeGuide(for: id) }
        save()
    }

    /// What `options` picks out, as a `.grade` file.
    func backupData(_ options: BackupOptions = BackupOptions()) throws -> Data {
        try GradeBackup.encoder.encode(backupContents(options))
    }

    /// "Grade 1º Año 2026-10-30.grade": what the exported file is called.
    func backupFileName(_ options: BackupOptions) -> String {
        let scope = options.scope == .all ? "" : " \(scopeFileName(options.scope))"
        return "Grade\(scope) \(Date.now.formatted(.iso8601.year().month().day())).grade"
    }

    /// What `options` picks out — every subject in its scope with its evaluation and dates, plus
    /// the degree settings, and the grades, guides and views when asked — ready to encode.
    func backupContents(_ options: BackupOptions = BackupOptions()) -> GradeBackup {
        let ids = Set(records(in: options.scope).map(\.id))
        let courses = self.courses.compactMap { course -> Course? in
            var course = course
            course.subjects = course.subjects.filter { ids.contains($0.id) }.map { record in
                guard !options.includesGrades else { return record }
                var record = record
                record.entries = [:]
                record.extraordinaryEntries = [:]
                return record
            }
            return course.subjects.isEmpty ? nil : course
        }
        let picked = options.scope == .all ? self.archives.filter { !options.excludedArchives.contains($0.id) } : []
        let archives = picked.isEmpty ? nil : picked
        let guideIDs = ids.union(archives?.flatMap(\.subjectIDs) ?? [])
        let guides = options.includesGuides ? guides(for: guideIDs) : nil
        let selections = options.includesViews ? self.selections.compactMap { selection -> CustomSelection? in
            var selection = selection
            selection.subjectIDs.removeAll { !ids.contains($0) }
            return selection.subjectIDs.isEmpty ? nil : selection
        } : nil
        var backup = GradeBackup(courses: courses, degree: degree, guides: guides, selections: selections)
        backup.includesGrades = options.includesGrades
        backup.scope = options.scope == .all ? nil : options.scope.title(in: degree)
        backup.archives = archives
        return backup
    }

    /// Replaces the current study with a backup's. Archived studies are never dropped: the
    /// copy's are added next to them.
    func restore(_ backup: GradeBackup) {
        let replaced = Set(courses.flatMap(\.subjects).map(\.id))
        courses = backup.courses
        degree = backup.degree
        hasStudy = true
        selections = backup.selections ?? []
        normalize()
        addArchives(of: backup)
        // The guides of subjects that are gone go too; one the copy still has keeps its guide
        // even if the copy was made without guides.
        for id in guideIDs.intersection(replaced).subtracting(subjectIDsInUse) { removeGuide(for: id) }
        restoreGuides(of: backup)
        save()
    }

    /// Every subject id in the current study or an archived one: what a guide can belong to.
    private var subjectIDsInUse: Set<SubjectRecord.ID> {
        Set(courses.flatMap(\.subjects).map(\.id) + archives.flatMap(\.subjectIDs))
    }

    /// Adds a backup's subjects to what's already here: one with the same id is replaced (keeping
    /// its grades when the copy was made without them), the rest are added to their year. The
    /// degree settings stay as they are, unless there's no current study: then the copy's start one.
    func merge(_ backup: GradeBackup) {
        if !hasStudy {
            degree = backup.degree
            hasStudy = true
        }
        let keepsGrades = backup.includesGrades == false
        for course in backup.courses {
            for var record in course.subjects {
                if let existing = self.record(id: record.id) {
                    if keepsGrades {
                        record.entries = existing.entries
                        record.extraordinaryEntries = existing.extraordinaryEntries
                    }
                    removeSubject(record.id)
                }
                courses[courseIndex(forYear: course.year)].subjects.append(record)
            }
        }
        for selection in backup.selections ?? [] {
            if let index = selections.firstIndex(where: { $0.id == selection.id }) {
                selections[index] = selection
            } else {
                selections.append(selection)
            }
        }
        normalize()
        addArchives(of: backup)
        restoreGuides(of: backup)
        save()
    }

    private func addArchives(of backup: GradeBackup) {
        let known = Set(archives.map(\.id))
        archives += (backup.archives ?? []).filter { !known.contains($0.id) }
    }

    /// "1º Año 1º Cuatrimestre", for an exported file's name.
    func scopeFileName(_ scope: DataScope) -> String {
        scope.title(in: degree).replacingOccurrences(of: " · ", with: " ")
    }

    private func restoreGuides(of backup: GradeBackup) {
        let ids = Set(courses.flatMap(\.subjects).map(\.id) + archives.flatMap(\.subjectIDs))
        for (key, data) in backup.guides ?? [:] {
            if let id = UUID(uuidString: key), ids.contains(id) { try? setGuide(data, for: id) }
        }
    }

    // MARK: Studies

    /// Puts the current study away, subjects, grades, views and guides included, and leaves no
    /// current study until one is created or resumed.
    func archiveCurrentStudy() {
        archives.append(ArchivedStudy(degree: degree, courses: courses, selections: selections))
        courses = []
        selections = []
        degree = DegreeSettings()
        hasStudy = false
        save()
    }

    /// A new, empty current study with these settings.
    func startStudy(_ settings: DegreeSettings) {
        degree = settings
        hasStudy = true
        save()
    }

    /// Makes an archived study the current one again; the current one takes its place in the
    /// archive unless it's empty.
    func resumeArchivedStudy(id: ArchivedStudy.ID) {
        guard let index = archives.firstIndex(where: { $0.id == id }) else { return }
        let resumed = archives.remove(at: index)
        if courses.contains(where: { !$0.subjects.isEmpty }) {
            archives.append(ArchivedStudy(degree: degree, courses: courses, selections: selections))
        }
        courses = resumed.courses
        degree = resumed.degree
        hasStudy = true
        selections = resumed.selections
        normalize()
        save()
    }

    /// Everything gone, as on a fresh install: the current study and its settings, the archived
    /// ones and every guide. Per-device preferences (sort, calendar filter…) stay.
    func eraseAll() {
        for id in guideIDs { removeGuide(for: id) }
        courses = []
        degree = DegreeSettings()
        hasStudy = true
        selections = []
        archives = []
        save()
    }

    func deleteArchivedStudy(id: ArchivedStudy.ID) {
        guard let index = archives.firstIndex(where: { $0.id == id }) else { return }
        let removed = archives.remove(at: index).subjectIDs
        // A subject can be in two places (a copy imported after archiving it): its guide stays
        // while either still has it.
        for subject in Set(removed).subtracting(subjectIDsInUse) { removeGuide(for: subject) }
        save()
    }

    /// Adds the template's subjects, each in its year and term. A subject the course already has
    /// (same name) is left alone, so applying a template twice never duplicates or loses grades.
    /// `only` limits it to those entries (by index); `nil` adds them all.
    @discardableResult
    func apply(_ template: DegreeTemplate, only: Set<Int>? = nil) -> (added: Int, skipped: Int) {
        var added = 0
        var skipped = 0
        // A template is a whole study's subjects: applying one with no study starts one.
        hasStudy = true
        for (index, entry) in template.entries.enumerated() where only?.contains(index) ?? true {
            let course = courseIndex(forYear: entry.year)
            if courses[course].subjects.contains(where: { $0.subject.name == entry.subject.name }) {
                skipped += 1
                continue
            }
            let term = degree.absoluteTerm(year: entry.year, relative: min(entry.term, degree.termsPerYear))
            courses[course].subjects.append(SubjectRecord(subject: entry.subject, term: term))
            added += 1
        }
        save()
        return (added, skipped)
    }

    private func mutateRecord(_ id: SubjectRecord.ID, _ body: (inout SubjectRecord) -> Void) {
        for course in courses.indices {
            if let index = courses[course].subjects.firstIndex(where: { $0.id == id }) {
                body(&courses[course].subjects[index])
                save()
                return
            }
        }
    }

    private func save() {
        guard let fileURL, !isWaitingForFile else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.fileEncoder.encode(Snapshot(courses: courses, degree: degree, selections: selections, archives: archives, hasStudy: hasStudy))
                .write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Couldn't save the library: \(error)")
        }
    }
}

/// What the engine says about one subject given what's been entered — the numbers the home card,
/// the detail screen and the record tab show.
struct SubjectProgress {
    let worst: Double
    let best: Double
    let threshold: Double
    let status: PassStatus
    /// Average needed on everything pending (out of 10) to reach `threshold`, when still in play.
    let neededAverage: Double?
    let enteredCount: Int
    let leafCount: Int
    let inputs: [String: Double]
    /// "Por definir": nothing is worked out, so it never has a final grade, however many are in.
    let isUndecided: Bool
    /// "No presentado" in this sitting: no grade, not a fail.
    let isNotPresented: Bool
    /// A requirement (attendance…) marked as not met: failed whatever the grades.
    let missesARequirement: Bool
    /// "Matrícula de honor", only once the final grade is in.
    let hasHonors: Bool
    /// What the engine aims at: the pass mark, lowered to what rounds up to it when the
    /// transcript rounds (4,95 for a 5).
    let target: Double

    var isComplete: Bool { !isUndecided && !isNotPresented && leafCount > 0 && enteredCount == leafCount }

    let session: Convocatoria

    /// `part`, for the numbers of one part alone (a term of a subject graded per term) instead of
    /// the whole subject's.
    init(_ record: SubjectRecord, session: Convocatoria? = nil, rounding: GradeRounding = .none, part: Node? = nil) {
        let session = session ?? record.activeSession
        let root = part ?? record.root(for: session)
        var inputs = Self.inputs(record, session: session)
        if part != nil {
            let leaves = Set(root.allLeafNames())
            inputs = inputs.filter { leaves.contains($0.key) }
        }
        self.session = session
        let threshold = root.minimumThreshold ?? 5
        let target = rounding.lowestPassing(threshold)
        var status = root.status(inputs, threshold: target)
        if record.missesARequirement { status = .impossible }

        self.inputs = inputs
        self.worst = rounding.apply(root.evaluate(inputs, pendingFraction: 0))
        self.best = rounding.apply(root.evaluate(inputs, pendingFraction: 1))
        self.threshold = threshold
        self.target = target
        self.status = status
        self.neededAverage = status == .possible ? root.neededFraction(inputs, target: target).map { $0 * 10 } : nil
        self.enteredCount = inputs.count
        self.leafCount = root.allLeafNames().count
        self.isUndecided = record.isUndecided
        self.isNotPresented = record.isNotPresented(in: session)
        self.missesARequirement = record.missesARequirement
        self.hasHonors = part == nil && record.hasHonors && leafCount > 0 && enteredCount == leafCount
    }

    /// What the engine reads for one sitting — without the status and needed-grade search, for
    /// views that only need the values.
    static func inputs(_ record: SubjectRecord, session: Convocatoria) -> [String: Double] {
        inputs(for: record.root(for: session), entries: record.entries(for: session))
    }

    /// Entries converted from whatever scale the user typed them on to each leaf's own scale.
    private static func inputs(for root: Node, entries: [String: GradeEntry]) -> [String: Double] {
        entries.reduce(into: [:]) { result, pair in
            let (name, entry) = pair
            guard entry.value.isFinite, entry.outOf.isFinite, entry.outOf > 0,
                  let max = root.leaf(named: name)?.scaleMax, max.isFinite else { return }
            result[name] = min(Swift.max(entry.value / entry.outOf * max, 0), max)
        }
    }
}

/// A condition with no grade (compulsory attendance, handing in every lab…): failing one fails the
/// subject. `isMet` is `nil` until it's known.
struct SubjectRequirement: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isMet: Bool?
}
