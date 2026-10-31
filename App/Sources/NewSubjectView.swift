import SwiftUI

/// What the sheet does: make a subject in a period, or move an existing one to another.
enum SubjectPlacement: Identifiable {
    case create(Period)
    case move(SubjectRecord.ID, name: String, from: Period)

    var id: String {
        switch self {
        case .create: "create"
        case .move(let id, _, _): id.uuidString
        }
    }
}

/// A small form: name (when creating) plus the year and term the subject belongs to.
struct NewSubjectView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(Tour.self) private var tour: Tour?

    let placement: SubjectPlacement
    /// Called with the subject's new period once saved, so the home screen can follow it.
    /// Where the subject ended up, and its id (the new one when creating).
    var onSaved: (Period, SubjectRecord.ID) -> Void = { _, _ in }

    @State private var name = ""
    @State private var year: Int
    /// Position within the year (1 or 2); `nil` means the subject lasts the whole year.
    @State private var relativeTerm: Int?
    @FocusState private var nameFocused: Bool

    init(placement: SubjectPlacement, degree: DegreeSettings, onSaved: @escaping (Period, SubjectRecord.ID) -> Void = { _, _ in }) {
        self.placement = placement
        self.onSaved = onSaved
        let period: Period = switch placement {
        case .create(let period): period
        case .move(_, _, let period): period
        }
        _year = State(initialValue: period.year)
        // Bachillerato and ESO subjects usually last the whole year, so new ones start that way.
        let startsYearLong = { if case .create = placement { degree.studyType.gradesPerTerm } else { false } }()
        _relativeTerm = State(initialValue: startsYearLong ? nil : period.term.map(degree.relativeTerm))
    }

    private var degree: DegreeSettings { library.degree }

    private var isCreating: Bool {
        if case .create = placement { true } else { false }
    }

    private var canSave: Bool {
        !isCreating || !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCreating {
                    Section {
                        InlineField("Nombre") {
                            TextField("Nueva asignatura", text: $name)
                                .focused($nameFocused)
                                .submitLabel(.done)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }
                        .tourTarget("new.name")
                    }
                }

                Section {
                    LabeledContent(degree.displayYearName) {
                        HStack(spacing: 10) {
                            Text(degree.yearLabel(year))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                            StepButton(systemImage: "minus", label: "Año anterior", isEnabled: year > 1) { year -= 1 }
                            StepButton(systemImage: "plus", label: "Año siguiente", isEnabled: year < max(degree.years, year)) { year += 1 }
                        }
                        .animation(.snappy, value: year)
                    }
                    .tourTarget("new.period")
                    Picker(degree.termName.isEmpty ? "Cuatrimestre" : degree.termName, selection: $relativeTerm) {
                        Text("Todo el año").tag(Int?.none)
                        ForEach(1...max(degree.termsPerYear, 1), id: \.self) { n in
                            Text(degree.termLabel(degree.absoluteTerm(year: year, relative: n))).tag(Int?.some(n))
                        }
                    }
                    .tourTarget("new.period")
                } footer: {
                    Text("Si la asignatura dura todo el año, elige «Todo el año»: aparecerá en todos sus periodos.")
                }
            }
            // Everything fits at this height: with the keyboard down, a drag on the form moves the
            // sheet itself (as from its title) instead of scrolling the rows up inside it.
            .scrollDisabled(!nameFocused)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save)
                        .tint(.blue)
                        .disabled(!canSave)
                        .accessibilityLabel(isCreating ? "Añadir" : "Mover")
                }
            }
            .onAppear {
                nameFocused = isCreating
                if isCreating { tour?.perform(.newSubjectOpened) }
            }
        }
        .presentationDetents([.medium])
        // A half-height sheet is glass by default; this gives it the same solid grouped background
        // as the full-height editor sheets.
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private var title: String {
        switch placement {
        case .create: "Nueva asignatura"
        case .move(_, let name, _): name
        }
    }

    private func save() {
        let term = relativeTerm.map { degree.absoluteTerm(year: year, relative: $0) }
        let id: SubjectRecord.ID
        switch placement {
        case .create:
            id = library.addSubject(
                name: name.trimmingCharacters(in: .whitespaces),
                year: year,
                term: term
            )
        case .move(let moved, _, _):
            id = moved
            library.move(moved, toYear: year, term: term)
        }
        onSaved(Period(year: year, term: term), id)
        dismiss()
        if isCreating { tour?.perform(.subjectCreated) }
    }
}
