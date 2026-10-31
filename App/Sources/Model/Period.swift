import Foundation

/// What the user is studying. Only a university degree shapes the app today (credits, templates);
/// the rest are there so the choice exists, and pick sensible years and terms.
enum StudyType: String, Codable, CaseIterable, Identifiable {
    case university, master, vocational, highSchool, secondary, other

    var id: Self { self }

    var label: String {
        switch self {
        case .university: "Grado universitario"
        case .master: "Máster"
        case .vocational: "Formación Profesional"
        case .highSchool: "Bachillerato"
        case .secondary: "ESO"
        case .other: "Otros estudios"
        }
    }

    var symbol: String {
        switch self {
        case .university: "graduationcap"
        case .master: "building.columns"
        case .vocational: "wrench.and.screwdriver"
        case .highSchool: "books.vertical"
        case .secondary: "backpack"
        case .other: "square.grid.2x2"
        }
    }

    /// Whether its subjects usually carry credits (ECTS): university degrees and masters do.
    var usesCredits: Bool { self == .university || self == .master }

    /// The usual years, terms per year and term name, applied when the type is picked. `nil` for
    /// `.other`, which keeps whatever was set.
    var defaults: (years: Int, termsPerYear: Int, termName: String)? {
        switch self {
        case .university: (4, 2, "Cuatrimestre")
        case .master: (1, 2, "Cuatrimestre")
        case .vocational: (2, 3, "Trimestre")
        case .highSchool: (2, 3, "Trimestre")
        case .secondary: (4, 3, "Trimestre")
        case .other: nil
        }
    }
}

/// How the transcript turns the worked-out grade into the final one: as it is, or to one decimal
/// rounding (4,95 → 5,0) or cutting (4,99 → 4,9) — it decides a pass right at the line.
enum GradeRounding: String, Codable, CaseIterable, Identifiable {
    case none, round, truncate

    var id: Self { self }

    var label: String {
        switch self {
        case .none: "Sin redondear"
        case .round: "A una décima, redondeando"
        case .truncate: "A una décima, truncando"
        }
    }

    func apply(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        switch self {
        case .none: return value
        // A hair added first, so a 4,95 that's 4,9499999… in binary still goes up.
        case .round: return (value * 10 + 1e-9).rounded(.toNearestOrAwayFromZero) / 10
        case .truncate: return (value * 10 + 1e-9).rounded(.towardZero) / 10
        }
    }

    /// The lowest worked-out grade that ends up at `threshold` or above.
    func lowestPassing(_ threshold: Double) -> Double {
        self == .round ? threshold - 0.05 - 1e-9 : threshold
    }
}

/// How the user's degree is divided, set in the account tab: what they study, how many years it
/// has and what its terms are (cuatrimestres, semestres, trimestres…). Stored term numbers are
/// degree-wide, so this is also what turns them into "1º Cuatrimestre" on screen. Years and
/// terms are named by the user ("Año", "Curso"; "Cuatrimestre", "Trimestre"…).
struct DegreeSettings: Codable, Equatable {
    static let maxYears = 10
    static let maxTermsPerYear = 4
    static let defaultTermName = "Cuatrimestre"
    static let defaultYearName = "Año"

    var studyType = StudyType.university
    /// What the user calls it ("Ingeniería Informática"); empty shows the study type.
    var name = ""
    /// Where ("UDC"); optional.
    var institution = ""
    var years = 4
    var termsPerYear = 2
    var termName = defaultTermName
    var yearName = defaultYearName
    /// Off: no credits anywhere (record, editor) and averages count every subject the same.
    var usesCredits = true
    var rounding = GradeRounding.none

    /// The name given to the study, or its type when it has none.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? studyType.label : trimmed
    }

    /// The study type with its usual years and terms.
    func switching(to type: StudyType) -> DegreeSettings {
        var new = self
        new.studyType = type
        if type != .other { new.usesCredits = type.usesCredits }
        if let defaults = type.defaults {
            new.years = defaults.years
            new.termsPerYear = defaults.termsPerYear
            new.termName = defaults.termName
        }
        return new
    }

    /// "4 años · 2 cuatrimestres por año", for the collapsed studies row.
    var summary: String {
        let years = years == 1 ? "1 año" : "\(years) años"
        let name = displayTermName.lowercased()
        let terms = termsPerYear == 1 ? "1 \(name)" : "\(termsPerYear) \(Self.plural(name))"
        return "\(years) · \(terms) por año"
    }

    /// "Trimestres", or the plural of whatever the terms are called.
    var pluralTermName: String { Self.plural(displayTermName) }

    private static func plural(_ word: String) -> String {
        if word.hasSuffix("ón") { return word.dropLast(2) + "ones" }
        if let last = word.last, "aeiou".contains(last) { return word + "s" }
        return word + "es"
    }

    /// "Año", or what the user calls the years.
    var displayYearName: String {
        let trimmed = yearName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultYearName : trimmed
    }

    private var displayTermName: String {
        let trimmed = termName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultTermName : trimmed
    }

    /// Never below 1, whatever a file says, since it divides.
    private var safeTermsPerYear: Int { Swift.max(termsPerYear, 1) }

    /// The term's position within its own year: with 2 per year, 3 → 1 and 4 → 2.
    func relativeTerm(_ term: Int) -> Int {
        let count = safeTermsPerYear
        return ((term - 1) % count + count) % count + 1
    }

    /// The degree-wide term for the `n`th term of a year: year 2, 1st → 3.
    func absoluteTerm(year: Int, relative n: Int) -> Int {
        (year - 1) * safeTermsPerYear + n
    }

    /// "2º Año", or whatever the years are called.
    func yearLabel(_ year: Int) -> String {
        "\(year)º \(displayYearName)"
    }

    /// "1º Cuatrimestre", for a degree-wide term number.
    func termLabel(_ term: Int) -> String {
        "\(relativeTerm(term))º \(displayTermName)"
    }
}

extension DegreeSettings {
    private enum CodingKeys: String, CodingKey { case studyType, name, institution, years, termsPerYear, termName, yearName, usesCredits, rounding }

    /// Clamped to what the settings screen allows, so a hand-edited backup can't hand the app zero
    /// terms a year (which it divides by) or a hundred years.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let years = try container.decodeIfPresent(Int.self, forKey: .years) ?? 4
        let terms = try container.decodeIfPresent(Int.self, forKey: .termsPerYear) ?? 2
        let studyType = (try? container.decodeIfPresent(StudyType.self, forKey: .studyType)) ?? .university
        self.init(
            studyType: studyType,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            institution: try container.decodeIfPresent(String.self, forKey: .institution) ?? "",
            years: min(max(years, 1), Self.maxYears),
            termsPerYear: min(max(terms, 1), Self.maxTermsPerYear),
            termName: try container.decodeIfPresent(String.self, forKey: .termName) ?? Self.defaultTermName,
            yearName: try container.decodeIfPresent(String.self, forKey: .yearName) ?? Self.defaultYearName,
            // Studies saved before the setting existed get their type's usual one.
            usesCredits: try container.decodeIfPresent(Bool.self, forKey: .usesCredits) ?? studyType.usesCredits,
            rounding: (try? container.decodeIfPresent(GradeRounding.self, forKey: .rounding)) ?? .none
        )
    }
}

/// A year of the degree and, optionally, one of its terms (`nil` = the whole year).
struct Period: Hashable {
    var year: Int
    /// Degree-wide term number (1-based).
    var term: Int?

    init(year: Int, term: Int? = nil) {
        self.year = year
        self.term = term
    }

    func title(in degree: DegreeSettings) -> String {
        degree.yearLabel(year)
    }

    func subtitle(in degree: DegreeSettings) -> String? {
        term.map(degree.termLabel)
    }
}

/// A study put away to start another (high school before university, a finished degree…): its
/// settings, subjects with their grades, and custom views, kept to look back at or pick up again.
struct ArchivedStudy: Identifiable, Codable, Equatable {
    var id = UUID()
    var degree: DegreeSettings
    var courses: [Course]
    var selections: [CustomSelection] = []
    var archivedAt = Date.now

    var subjectIDs: [SubjectRecord.ID] { courses.flatMap(\.subjects).map(\.id) }
}
