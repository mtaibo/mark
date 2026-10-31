import Engine
import Foundation
import Testing
@testable import AppModel

/// A library in a folder of its own, removed afterwards.
@MainActor
final class Sandbox {
    let folder = FileManager.default.temporaryDirectory.appending(path: "GradeTests-\(UUID().uuidString)")
    var file: URL { folder.appending(path: "library.json") }

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func open() -> Library { Library(fileURL: file) }
}

@MainActor
struct LibraryTests {
    /// Labs 40 % and a final exam 60 %.
    static func subject(_ name: String = "Física") -> Subject {
        Subject(name: name, ectsCredits: 6, root: .group(Group(name: name, combination: .weightedAverage, children: [
            WeightedChild(weight: 0.4, node: .grade(Grade(name: "Prácticas"))),
            WeightedChild(weight: 0.6, node: .grade(Grade(name: "Examen", isFinalExam: true))),
        ], minimum: Minimum(threshold: 5, consequence: .fails))))
    }

    static func sameContents(_ a: Library, _ b: Library) -> Bool {
        a.courses == b.courses && a.degree == b.degree && a.selections == b.selections
            && a.archives == b.archives && a.hasStudy == b.hasStudy
    }

    // MARK: Saving and loading

    @Test func everythingSavedComesBack() {
        let sandbox = Sandbox()
        let library = sandbox.open()
        let id = library.addSubject(Self.subject(), year: 2, term: 3)
        library.setEntry(GradeEntry(value: 1.6, outOf: 2), forLeaf: "Prácticas", in: id, session: .ordinary)
        library.setEntry(GradeEntry(value: 4, outOf: 10), forLeaf: "Examen", in: id, session: .extraordinary)
        library.setExamDate(Date(timeIntervalSinceReferenceDate: 815_000_000), for: .ordinary, in: id)
        library.setStyle(symbol: "atom", colorName: "blue", for: id)
        library.saveSelection(CustomSelection(title: .name("Mi vista"), subjectIDs: [id]))
        var degree = library.degree
        degree.name = "Física"
        degree.termName = "Semestre"
        library.updateDegree(degree)
        #expect(Self.sameContents(library, sandbox.open()))
    }

    @Test func aFileThatCantBeDecodedIsKeptAside() throws {
        let sandbox = Sandbox()
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: sandbox.file)
        let library = sandbox.open()
        #expect(library.courses.isEmpty)
        let aside = try FileManager.default.contentsOfDirectory(atPath: sandbox.folder.path).filter { $0.hasPrefix("library-unreadable-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: sandbox.folder.appending(path: aside[0])) == garbage)
    }

    /// iOS can launch the app before the phone is first unlocked, when the file can't be read: it
    /// must not be taken for a fresh install and saved over.
    @Test func aFileThatCantBeReadYetIsNeverSavedOver() throws {
        let sandbox = Sandbox()
        let first = sandbox.open()
        first.addSubject(Self.subject(), year: 1, term: 1)
        let saved = try Data(contentsOf: sandbox.file)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sandbox.file.path)
        let locked = sandbox.open()
        #expect(locked.courses.isEmpty)
        locked.addSubject(Self.subject("Química"), year: 1, term: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sandbox.file.path)
        #expect(try Data(contentsOf: sandbox.file) == saved)

        locked.reloadIfNeeded()
        #expect(locked.courses.flatMap(\.subjects).map(\.subject.name) == ["Física"])
    }

    @Test func aNonNumberNeverStopsTheFileFromSaving() {
        let sandbox = Sandbox()
        let library = sandbox.open()
        var subject = Self.subject()
        // A weight a form left empty, before the editor sanitises it.
        subject.root = .group(Group(name: "F", combination: .weightedAverage, children: [
            WeightedChild(weight: .nan, node: .grade(Grade(name: "A", scaleMax: .infinity))),
        ]))
        let id = library.addSubject(subject, year: 1, term: nil)
        library.setEntry(GradeEntry(value: .nan, outOf: 10), forLeaf: "A", in: id, session: .ordinary)
        #expect(library.record(id: id)?.entries.isEmpty == true)
        library.setEntry(GradeEntry(value: 5, outOf: 10), forLeaf: "A", in: id, session: .ordinary)
        let reopened = sandbox.open()
        #expect(reopened.record(id: id)?.entries["A"]?.value == 5)
        let progress = SubjectProgress(reopened.record(id: id)!)
        #expect(!progress.worst.isNaN && !progress.best.isNaN)
    }

    @Test func theFirstFileFormatStillLoads() throws {
        let sandbox = Sandbox()
        let id = UUID()
        let json = """
        [{"id":"\(UUID().uuidString)","name":"2.º curso","subjects":[{"id":"\(id.uuidString)",
        "subject":{"name":"Álgebra","ectsCredits":6,"root":{"grade":{"_0":{"name":"Examen","scaleMax":10}}}},
        "entries":{"Examen":{"value":7,"outOf":10}}}]}]
        """
        try Data(json.utf8).write(to: sandbox.file)
        let library = sandbox.open()
        #expect(library.year(of: id) == 2)
        #expect(library.record(id: id)?.entries["Examen"]?.value == 7)
        #expect(library.hasStudy)
    }

    @Test func whateverIsLoadedIsMadeSafe() throws {
        let sandbox = Sandbox()
        let shared = UUID()
        let record = SubjectRecord(id: shared, subject: Self.subject(), term: -2)
        let courses = [
            Course(year: 0, subjects: [record]),
            Course(year: 3, subjects: [SubjectRecord(id: shared, subject: Self.subject("Otra"))]),
            Course(year: 1, subjects: [SubjectRecord(subject: Self.subject("Más"))]),
        ]
        try Library.fileEncoder.encode(courses).write(to: sandbox.file)
        let library = sandbox.open()
        // Year 0 joins year 1, years in order, ids unique, a term below 1 is year-long.
        #expect(library.courses.map(\.year) == [1, 3])
        let ids = library.courses.flatMap(\.subjects).map(\.id)
        #expect(Set(ids).count == 3)
        #expect(library.record(id: shared)?.term == nil)
    }

    @Test func degreeSettingsAreClampedWhenRead() throws {
        let json = #"{"years": 400, "termsPerYear": 0, "studyType": "spaceship"}"#
        let degree = try JSONDecoder().decode(DegreeSettings.self, from: Data(json.utf8))
        #expect(degree.years == DegreeSettings.maxYears)
        #expect(degree.termsPerYear == 1)
        #expect(degree.studyType == .university)
        #expect(degree.relativeTerm(5) == 1)
    }

    // MARK: Grades and sittings

    @Test func gradesAreReadOnTheLeafScale() {
        var record = SubjectRecord(subject: Self.subject())
        record.entries = [
            "Prácticas": GradeEntry(value: 1.5, outOf: 2),
            // Above the maximum, and for a leaf that no longer exists.
            "Examen": GradeEntry(value: 14, outOf: 10),
            "Borrada": GradeEntry(value: 3, outOf: 10),
        ]
        let inputs = SubjectProgress.inputs(record, session: .ordinary)
        #expect(inputs == ["Prácticas": 7.5, "Examen": 10])
        let progress = SubjectProgress(record)
        #expect(abs(progress.worst - 9) < 1e-9)
        #expect(progress.isComplete)
    }

    @Test func theExtraordinaryKeepsEverythingButTheExam() {
        var record = SubjectRecord(subject: Self.subject())
        record.entries = ["Prácticas": GradeEntry(value: 8, outOf: 10), "Examen": GradeEntry(value: 3, outOf: 10)]
        #expect(record.activeSession == .ordinary)
        #expect(record.entry(for: "Prácticas", in: .extraordinary)?.value == 8)
        #expect(record.entry(for: "Examen", in: .extraordinary) == nil)
        #expect(record.isCarriedOver("Prácticas", in: .extraordinary))
        record.extraordinaryEntries["Examen"] = GradeEntry(value: 6, outOf: 10)
        #expect(record.activeSession == .extraordinary)
        let progress = SubjectProgress(record)
        #expect(abs(progress.worst - 6.8) < 1e-9)
        #expect(progress.status == .guaranteed)
    }

    @Test func aSectionSentToTheExtraordinaryIsTakenAgain() {
        var subject = Self.subject()
        subject.root = .group(Group(name: "F", combination: .weightedAverage, children: [
            WeightedChild(weight: 0.4, node: .grade(Grade(name: "Prácticas", minimum: Minimum(threshold: 4, consequence: .sendsToExtraordinary)))),
            WeightedChild(weight: 0.6, node: .grade(Grade(name: "Examen", isFinalExam: true))),
        ]))
        var record = SubjectRecord(subject: subject)
        record.entries = ["Prácticas": GradeEntry(value: 2, outOf: 10), "Examen": GradeEntry(value: 9, outOf: 10)]
        #expect(SubjectProgress(record, session: .ordinary).status == .impossible)
        #expect(record.entry(for: "Prácticas", in: .extraordinary) == nil)
        record.extraordinaryEntries = ["Prácticas": GradeEntry(value: 5, outOf: 10), "Examen": GradeEntry(value: 5, outOf: 10)]
        #expect(SubjectProgress(record).status == .guaranteed)
    }

    @Test func anUndecidedSubjectNeverHasAFinalGrade() {
        var subject = Self.subject()
        subject.root = .group(Group(name: "F", combination: .undecided, children: [
            WeightedChild(weight: 0, node: .grade(Grade(name: "A"))),
        ]))
        var record = SubjectRecord(subject: subject)
        record.entries["A"] = GradeEntry(value: 9, outOf: 10)
        #expect(record.isUndecided)
        #expect(!SubjectProgress(record).isComplete)
        #expect(RecordSummary([Course(year: 1, subjects: [record])], degree: DegreeSettings()).average == nil)
    }

    @Test func aSingleGradeSubjectHasOneSitting() {
        var record = SubjectRecord(subject: Subject(name: "Inglés", ectsCredits: 6, root: .grade(Grade(name: "Nota final", category: .exam))))
        record.extraordinaryEntries["Nota final"] = GradeEntry(value: 7, outOf: 10)
        #expect(record.isSingleGrade)
        #expect(record.activeSession == .ordinary)
    }

    @Test func examGradeDatesMoveToTheSitting() {
        var subject = Self.subject()
        subject.root.setDate(Date(timeIntervalSinceReferenceDate: 1000), forLeaf: "Examen")
        var record = SubjectRecord(subject: subject)
        record.moveExamGradeDates()
        #expect(record.ordinaryExamDate == Date(timeIntervalSinceReferenceDate: 1000))
        #expect(record.subject.root.grades.allSatisfy { $0.date == nil })
    }

    // MARK: Subjects

    @Test func reorderingWithStaleIdsNeverLosesASubject() {
        let library = Sandbox().open()
        let a = library.addSubject(Self.subject("A"), year: 1, term: 1)
        let b = library.addSubject(Self.subject("B"), year: 1, term: 1)
        let c = library.addSubject(Self.subject("C"), year: 1, term: 2)
        let other = library.addSubject(Self.subject("D"), year: 2, term: 3)
        library.reorderSubjects([b], before: a, among: [a, b])
        #expect(library.courses[0].subjects.map(\.id) == [b, a, c])
        // A deleted subject and one from another year in the request: nothing breaks.
        library.reorderSubjects([UUID(), other], before: nil, among: [b, a, UUID(), other])
        #expect(Set(library.courses.flatMap(\.subjects).map(\.id)) == [a, b, c, other])
        #expect(library.courses.flatMap(\.subjects).count == 4)
    }

    @Test func changingTermsPerYearKeepsEachSubjectInItsYear() {
        let library = Sandbox().open()
        var degree = library.degree
        degree.termsPerYear = 4
        library.updateDegree(degree)
        let last = library.addSubject(Self.subject("Última"), year: 2, term: degree.absoluteTerm(year: 2, relative: 4))
        degree.termsPerYear = 2
        library.updateDegree(degree)
        #expect(library.year(of: last) == 2)
        #expect(library.record(id: last)?.term == 4)
    }

    @Test func schoolSubjectsLastingTheYearStartWithAGradePerTerm() throws {
        let library = Sandbox().open()
        var degree = library.degree
        degree.studyType = .secondary
        degree.termsPerYear = 3
        degree.termName = "Trimestre"
        library.updateDegree(degree)
        let annual = try #require(library.record(id: library.addSubject(name: "Filosofía", year: 1, term: nil)))
        #expect(annual.isPerTerm)
        #expect(annual.subject.root.asGroup?.children.map(\.node.title) == ["1º Trimestre", "2º Trimestre", "3º Trimestre"])
        // One term only, or a university degree: a single evaluation as before.
        let termOnly = try #require(library.record(id: library.addSubject(name: "Música", year: 1, term: 2)))
        #expect(!termOnly.isPerTerm)
        degree.studyType = .university
        library.updateDegree(degree)
        #expect(library.record(id: library.addSubject(name: "Álgebra", year: 1, term: nil))?.isPerTerm == false)
    }

    @Test func applyingATemplateTwiceAddsNothingTheSecondTime() throws {
        let library = Sandbox().open()
        let template = try #require(DegreeTemplate.all.first)
        let first = library.apply(template)
        #expect(first.added == template.entries.count)
        let second = library.apply(template)
        #expect(second.added == 0 && second.skipped == template.entries.count)
        // Fewer terms than the template expects still puts everything in a valid term.
        let single = Sandbox().open()
        var degree = single.degree
        degree.termsPerYear = 1
        single.updateDegree(degree)
        single.apply(template)
        for course in single.courses {
            for subject in course.subjects { #expect(subject.term == nil || subject.term == course.year) }
        }
    }

    @Test func deletingASubjectTakesItOutOfEveryView() {
        let library = Sandbox().open()
        let a = library.addSubject(Self.subject("A"), year: 1, term: 1)
        let b = library.addSubject(Self.subject("B"), year: 1, term: 1)
        library.saveSelection(CustomSelection(title: .automatic, subjectIDs: [a, b]))
        library.deleteSubject(id: a)
        #expect(library.selections.first?.subjectIDs == [b])
        #expect(library.record(id: a) == nil)
    }

    @Test func clearingAndRemovingRespectTheScope() {
        let library = Sandbox().open()
        let first = library.addSubject(Self.subject("A"), year: 1, term: 1)
        let second = library.addSubject(Self.subject("B"), year: 2, term: 3)
        for id in [first, second] { library.setEntry(GradeEntry(value: 5, outOf: 10), forLeaf: "Examen", in: id, session: .ordinary) }
        library.clearGrades(in: .year(2))
        #expect(library.record(id: first)?.entries.isEmpty == false)
        #expect(library.record(id: second)?.entries.isEmpty == true)
        library.removeSubjects(in: .term(1))
        #expect(library.record(id: first) == nil && library.record(id: second) != nil)
    }

    // MARK: Custom views

    @Test func aViewOfAWholeYearIsTitledWithTheYear() {
        let library = Sandbox().open()
        let a = library.addSubject(Self.subject("A"), year: 1, term: 1)
        let b = library.addSubject(Self.subject("B"), year: 1, term: 2)
        let c = library.addSubject(Self.subject("C"), year: 2, term: 3)
        #expect(library.wholeYear(of: [a, b]) == 1)
        #expect(library.wholeYear(of: [a]) == nil)
        #expect(library.wholeYear(of: [a, b, c]) == nil)
        #expect(library.heading(for: CustomSelection(title: .automatic, subjectIDs: [a, b])).subtitle == nil)
        #expect(library.heading(for: CustomSelection(title: .automatic, subjectIDs: [a, c])).title == library.degree.yearLabel(2))
        #expect(library.heading(for: CustomSelection(title: .automatic, subjectIDs: [])).title == "Mi vista")
    }

    @Test func aViewOnlyTakesAReorderOfItsOwnSubjects() {
        let library = Sandbox().open()
        let a = library.addSubject(Self.subject("A"), year: 1, term: 1)
        let b = library.addSubject(Self.subject("B"), year: 1, term: 1)
        let view = CustomSelection(title: .automatic, subjectIDs: [a, b])
        library.saveSelection(view)
        library.reorderSelection(view.id, to: [b, a, a])
        #expect(library.selections[0].subjectIDs == [a, b])
        library.reorderSelection(view.id, to: [b, a])
        #expect(library.selections[0].subjectIDs == [b, a])
    }

    // MARK: Backups

    @Test func aFullBackupRestoresEverything() throws {
        let sandbox = Sandbox()
        let library = sandbox.open()
        let id = library.addSubject(Self.subject(), year: 1, term: 1)
        library.setEntry(GradeEntry(value: 7, outOf: 10), forLeaf: "Examen", in: id, session: .ordinary)
        try library.setGuide(Data("%PDF".utf8), for: id)
        library.saveSelection(CustomSelection(title: .name("V"), subjectIDs: [id]))
        library.archiveCurrentStudy()
        let kept = library.addSubject(Self.subject("Nueva"), year: 1, term: 1)

        let data = try library.backupData()
        let backup = try GradeBackup.decode(data)
        let other = Sandbox().open()
        other.restore(backup)
        #expect(other.courses == library.courses)
        // Copies store dates to the second (ISO 8601), which is all an archive date needs.
        #expect(other.archives.map(\.id) == library.archives.map(\.id))
        #expect(other.archives.map(\.courses) == library.archives.map(\.courses))
        #expect(zip(other.archives, library.archives).allSatisfy { abs($0.archivedAt.timeIntervalSince($1.archivedAt)) < 1 })
        #expect(other.guideIDs == [id])
        #expect(other.record(id: kept) != nil)
    }

    @Test func importingTheSameCopyTwiceDuplicatesNothing() throws {
        let library = Sandbox().open()
        let id = library.addSubject(Self.subject(), year: 1, term: 1)
        library.archiveCurrentStudy()
        library.addSubject(Self.subject("Nueva"), year: 1, term: 1)
        let backup = try GradeBackup.decode(library.backupData())
        library.merge(backup)
        library.merge(backup)
        #expect(library.courses.flatMap(\.subjects).count == 1)
        #expect(library.archives.count == 1)
        #expect(library.archives[0].subjectIDs == [id])
    }

    @Test func mergingACopyWithoutGradesKeepsMine() throws {
        let library = Sandbox().open()
        let id = library.addSubject(Self.subject(), year: 1, term: 1)
        library.setEntry(GradeEntry(value: 7, outOf: 10), forLeaf: "Examen", in: id, session: .ordinary)
        var options = BackupOptions()
        options.includesGrades = false
        let backup = try GradeBackup.decode(library.backupData(options))
        #expect(backup.courses[0].subjects[0].entries.isEmpty)
        library.merge(backup)
        #expect(library.record(id: id)?.entries["Examen"]?.value == 7)
    }

    @Test func aPartialCopyHoldsOnlyItsScope() throws {
        let library = Sandbox().open()
        let first = library.addSubject(Self.subject("A"), year: 1, term: 1)
        library.addSubject(Self.subject("B"), year: 2, term: 3)
        library.archiveCurrentStudy()
        library.addSubject(Self.subject("C"), year: 1, term: 1)
        _ = first
        var options = BackupOptions()
        options.scope = .year(1)
        let backup = library.backupContents(options)
        #expect(backup.subjectCount == 1)
        #expect(backup.archives == nil)
        #expect(backup.scope == library.degree.yearLabel(1))
    }

    @Test func mergingIntoNoStudyStartsOneFromTheCopy() throws {
        let source = Sandbox().open()
        var degree = source.degree
        degree.name = "Matemáticas"
        source.updateDegree(degree)
        source.addSubject(Self.subject(), year: 1, term: 1)
        let backup = try GradeBackup.decode(source.backupData())

        let target = Sandbox().open()
        target.addSubject(Self.subject("Vieja"), year: 1, term: 1)
        target.archiveCurrentStudy()
        #expect(!target.hasStudy)
        target.merge(backup)
        #expect(target.hasStudy)
        #expect(target.degree.name == "Matemáticas")
    }

    @Test func copiesThatArentOursAreRefused() throws {
        #expect(throws: BackupError.notABackup) { try GradeBackup.decode(Data("{}".utf8)) }
        #expect(throws: BackupError.notABackup) { try GradeBackup.decode(Data("[1, 2]".utf8)) }
        let library = Sandbox().open()
        var backup = library.backupContents()
        backup.version = GradeBackup.currentVersion + 1
        #expect(throws: BackupError.newerVersion) { try GradeBackup.decode(GradeBackup.encoder.encode(backup)) }
        backup.version = GradeBackup.currentVersion
        backup.format = "mark-backup"
        #expect(throws: Never.self) { try GradeBackup.decode(GradeBackup.encoder.encode(backup)) }
    }

    /// Restoring a copy made without guides keeps the guides of the subjects it still has.
    @Test func restoringWithoutGuidesKeepsThoseStillNeeded() throws {
        let library = Sandbox().open()
        let id = library.addSubject(Self.subject(), year: 1, term: 1)
        let gone = library.addSubject(Self.subject("Se va"), year: 1, term: 1)
        try library.setGuide(Data("%PDF".utf8), for: id)
        try library.setGuide(Data("%PDF".utf8), for: gone)
        var options = BackupOptions()
        options.includesGuides = false
        var backup = library.backupContents(options)
        backup.courses[0].subjects.removeAll { $0.id == gone }
        library.restore(backup)
        #expect(library.guideIDs == [id])
    }

    // MARK: Studies

    @Test func archivingResumingAndDeletingAStudy() throws {
        let library = Sandbox().open()
        let id = library.addSubject(Self.subject(), year: 1, term: 1)
        library.archiveCurrentStudy()
        #expect(!library.hasStudy && library.courses.isEmpty)
        let archive = try #require(library.archives.first)
        // Resuming with an empty current study doesn't archive the empty one.
        library.resumeArchivedStudy(id: archive.id)
        #expect(library.hasStudy && library.record(id: id) != nil && library.archives.isEmpty)
        library.archiveCurrentStudy()
        library.startStudy(DegreeSettings().switching(to: .master))
        let other = library.addSubject(Self.subject("Máster"), year: 1, term: 1)
        library.resumeArchivedStudy(id: library.archives[0].id)
        #expect(library.record(id: id) != nil)
        #expect(library.archives.count == 1 && library.archives[0].subjectIDs == [other])
        library.deleteArchivedStudy(id: library.archives[0].id)
        #expect(library.archives.isEmpty)
    }

    /// A subject both in an archived study and the current one (a copy imported after archiving)
    /// keeps its guide when either goes.
    @Test func aGuideSharedWithAnArchiveSurvivesEitherBeingDeleted() throws {
        let library = Sandbox().open()
        let id = library.addSubject(Self.subject(), year: 1, term: 1)
        try library.setGuide(Data("%PDF".utf8), for: id)
        let backup = try GradeBackup.decode(library.backupData())
        library.archiveCurrentStudy()
        library.merge(backup)
        #expect(library.record(id: id) != nil && library.archives[0].subjectIDs == [id])
        library.deleteArchivedStudy(id: library.archives[0].id)
        #expect(library.guideIDs == [id])
        library.deleteSubject(id: id)
        #expect(library.guideIDs.isEmpty)
    }

    @Test func eraseAllLeavesAFreshLibrary() throws {
        let sandbox = Sandbox()
        let library = sandbox.open()
        let id = library.addSubject(Self.subject(), year: 1, term: 1)
        try library.setGuide(Data("%PDF".utf8), for: id)
        library.archiveCurrentStudy()
        library.eraseAll()
        let reopened = sandbox.open()
        #expect(reopened.courses.isEmpty && reopened.archives.isEmpty && reopened.guideIDs.isEmpty)
        #expect(reopened.hasStudy && reopened.degree == DegreeSettings())
    }

    @Test func simulationsAndToursNeverTouchTheDisk() {
        let sandbox = Sandbox()
        let real = sandbox.open()
        let id = real.addSubject(Self.subject(), year: 1, term: 1)
        let simulation = Library(simulating: real.record(id: id)!, degree: real.degree)
        simulation.setEntry(GradeEntry(value: 10, outOf: 10), forLeaf: "Examen", in: id, session: .ordinary)
        let tour = Library(inMemory: DegreeSettings())
        tour.apply(DegreeTemplate.all[0])
        #expect(Self.sameContents(real, sandbox.open()))
        #expect(sandbox.open().record(id: id)?.entries.isEmpty == true)
    }

    // MARK: Anything, in any order

    /// A few thousand random operations, in random order: the library never ends up with a
    /// repeated subject id, a year below 1 or out of order, a view pointing at a deleted subject,
    /// and what's on disk always matches what's on screen.
    @Test(arguments: [1, 2, 3, 4])
    func randomUseNeverCorruptsTheLibrary(seed: UInt64) throws {
        let sandbox = Sandbox()
        let library = sandbox.open()
        var random = SeededGenerator(state: seed)
        var backups: [GradeBackup] = []

        for step in 0..<400 {
            let ids = library.courses.flatMap(\.subjects).map(\.id)
            let someID = ids.randomElement(using: &random) ?? UUID()
            switch Int.random(in: 0..<16, using: &random) {
            case 0, 1:
                library.addSubject(Self.subject("S\(step)"), year: Int.random(in: 1...4, using: &random), term: [nil, 1, 2, 3, 5, 8].randomElement(using: &random)!)
            case 2:
                library.deleteSubject(id: someID)
            case 3:
                library.move(someID, toYear: Int.random(in: 1...5, using: &random), term: [nil, 1, 4].randomElement(using: &random)!)
            case 4, 5:
                let value = [0, 5, 7.5, 10, 12, -3, .nan, .infinity].randomElement(using: &random)!
                library.setEntry(GradeEntry(value: value, outOf: [10, 2, 0, 100].randomElement(using: &random)!), forLeaf: ["Examen", "Prácticas", "Nada"].randomElement(using: &random)!, in: someID, session: Bool.random(using: &random) ? .ordinary : .extraordinary)
            case 6:
                library.saveSelection(CustomSelection(title: .automatic, subjectIDs: Array(ids.shuffled(using: &random).prefix(3))))
            case 7:
                if let view = library.selections.randomElement(using: &random) {
                    library.reorderSelection(view.id, to: view.subjectIDs.shuffled(using: &random))
                }
            case 8:
                library.reorderSubjects([someID], before: ids.randomElement(using: &random), among: ids.shuffled(using: &random))
            case 9:
                if Int.random(in: 0..<4, using: &random) == 0 { library.archiveCurrentStudy() }
            case 10:
                if let archive = library.archives.randomElement(using: &random) { library.resumeArchivedStudy(id: archive.id) }
            case 11:
                backups.append(try GradeBackup.decode(library.backupData()))
            case 12:
                if let backup = backups.randomElement(using: &random) {
                    Bool.random(using: &random) ? library.merge(backup) : library.restore(backup)
                }
            case 13:
                var degree = library.degree
                degree.termsPerYear = Int.random(in: 1...4, using: &random)
                library.updateDegree(degree)
            case 14:
                library.clearGrades(in: [.all, .year(1), .term(2)].randomElement(using: &random)!)
            default:
                if let archive = library.archives.randomElement(using: &random), Int.random(in: 0..<3, using: &random) == 0 {
                    library.deleteArchivedStudy(id: archive.id)
                }
            }

            let all = library.courses.flatMap(\.subjects)
            #expect(Set(all.map(\.id)).count == all.count, "repeated id at step \(step)")
            #expect(library.courses.map(\.year) == library.courses.map(\.year).sorted())
            #expect(Set(library.courses.map(\.year)).count == library.courses.count)
            #expect(library.courses.allSatisfy { $0.year >= 1 })
            for record in all {
                for entry in Array(record.entries.values) + Array(record.extraordinaryEntries.values) {
                    #expect(entry.value.isFinite && entry.outOf.isFinite && entry.outOf > 0)
                }
                let progress = SubjectProgress(record)
                #expect(progress.worst.isFinite && progress.best.isFinite)
            }
        }
        #expect(Self.sameContents(library, sandbox.open()))
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
