import Engine
import SwiftUI

/// Edits a subject's details and evaluation tree on a draft, committed only on the checkmark — the
/// modular part of the app: any subject's structure can be reshaped to match its real syllabus.
struct SubjectEditorView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// Seeded once from the record being edited; the library only changes on save.
    @State private var draft: SubjectRecord
    /// Each note's id when the editor opened, by its name then: stored grades follow their note's
    /// id to wherever it ends up and whatever it's called by the time it's saved.
    @State private var openingIDs: [String: UUID] = [:]
    @State private var openingExtraordinaryIDs: [String: UUID] = [:]
    /// The term it had before being made year-long, to go back to if switched off again.
    @State private var lastTerm: Int?

    init(record: SubjectRecord) {
        // Grades from before the type was required show the type they were already guessed as, so
        // only sections added from now on start without one.
        var record = record
        record.subject.root.updateGrades { grade in
            if grade.category == nil { grade.category = grade.kind }
        }
        record.subject.root.identifyGrades()
        record.extraordinaryRoot?.updateGrades { grade in
            if grade.category == nil { grade.category = grade.kind }
        }
        record.extraordinaryRoot?.identifyGrades()
        _draft = State(initialValue: record)
        _openingIDs = State(initialValue: record.subject.root.gradeIDsByName)
        _openingExtraordinaryIDs = State(initialValue: record.extraordinaryRoot?.gradeIDsByName ?? [:])
        _lastTerm = State(initialValue: record.term)
    }

    private var degree: DegreeSettings { library.degree }
    private var year: Int { library.year(of: draft.id) ?? 1 }

    /// On: the subject belongs to the whole year (no term) and shows in every one of its periods.
    /// Off: back to the term it had, or the year's first.
    private var isYearLong: Binding<Bool> {
        Binding(
            get: { draft.term == nil },
            set: { yearLong in
                if yearLong {
                    lastTerm = draft.term
                    draft.term = nil
                    // Bachillerato and ESO grade their year-long subjects per term.
                    if degree.studyType.gradesPerTerm, degree.termsPerYear > 1, !draft.isPerTerm { splitByTerm() }
                } else {
                    if draft.isPerTerm { mergeTerms() }
                    draft.term = lastTerm ?? degree.absoluteTerm(year: year, relative: 1)
                }
            }
        )
    }

    /// On: each term of the year gets its own evaluation and the root becomes the general one,
    /// which combines them. Off: back to a single evaluation.
    private var isPerTerm: Binding<Bool> {
        Binding(get: { draft.isPerTerm }, set: { $0 ? splitByTerm() : mergeTerms() })
    }

    /// "1º Trimestre", for the `n`th term of the subject's year.
    private func termLabel(_ n: Int) -> String {
        degree.termLabel(degree.absoluteTerm(year: year, relative: n))
    }

    /// What tells one term's copy of a part from another's: "Examen (1º Trimestre)".
    private func termSuffix(_ n: Int) -> String { " (\(termLabel(n)))" }

    private func splitByTerm() {
        draft.splitByTerm(degree.termLabels)
    }

    /// Keeps the first term's evaluation, with its grades, as the whole subject's.
    private func mergeTerms() {
        draft.isPerTerm = false
        guard case .group(let general) = draft.subject.root, var first = general.children.first?.node else { return }
        let suffix = termSuffix(1)
        first.renameLeaves { $0.hasSuffix(suffix) ? String($0.dropLast(suffix.count)) : $0 }
        if case .group(var group) = first {
            group.name = draft.subject.name
            first = .group(group)
        }
        draft.subject.root = first
    }

    /// Notes sharing a name within one evaluation. Two schemes, or the two sittings, may share a
    /// note on purpose: that's how the same exam is typed once.
    private var duplicateLeafNames: [String] {
        func duplicates(_ node: Node) -> Set<String> {
            if case .alternatives(let alternatives) = node {
                return alternatives.branches.reduce(into: []) { $0.formUnion(duplicates($1.node)) }
            }
            let names = node.grades.map(\.name)
            return Set(names.filter { name in names.count { $0 == name } > 1 })
        }
        return Array(duplicates(draft.subject.root).union(draft.extraordinaryRoot.map(duplicates) ?? [])).sorted()
    }

    /// Notes whose "Tipo" is still unpicked — it's required. New sections can't be added without
    /// one, so this only guards against a gap elsewhere (a new formula variable).
    private var untypedLeafNames: [String] {
        draft.subject.root.grades.filter { GradeType($0) == nil }.map(\.name)
    }

    private var canSave: Bool {
        !draft.subject.name.trimmingCharacters(in: .whitespaces).isEmpty && duplicateLeafNames.isEmpty && untypedLeafNames.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    InlineField("Nombre") {
                        TextField("Nombre", text: $draft.subject.name)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    .tourTarget("editor.name")
                } footer: {
                    Text("Nombre de la asignatura. Toca para cambiarlo.")
                }

                Section {
                    Toggle("Anual", isOn: isYearLong.animation())
                    if draft.term == nil {
                        Toggle("Nota por periodo", isOn: isPerTerm.animation())
                    }
                    if draft.term != nil {
                        Picker(degree.termName.isEmpty ? DegreeSettings.defaultTermName : degree.termName, selection: $draft.term) {
                            ForEach(1...max(degree.termsPerYear, 1), id: \.self) { n in
                                let term = degree.absoluteTerm(year: year, relative: n)
                                Text(degree.termLabel(term)).tag(Int?.some(term))
                            }
                        }
                    }
                } footer: {
                    if draft.isPerTerm {
                        Text("Cada periodo tiene su propia evaluación, y la de abajo es la general: cómo se juntan las notas de los periodos en la final. Aparece en todos los periodos del año.")
                    } else {
                        Text("Una asignatura anual aparece en todos los periodos de su año. Si no, solo en el que elijas. Con «Nota por periodo», cada periodo se evalúa por separado.")
                    }
                }

                NodeContentsSections(node: $draft.subject.root, isRoot: true, isPerTerm: draft.isPerTerm)

                if !duplicateLeafNames.isEmpty {
                    Section {
                        Label(
                            "Hay notas con el mismo nombre (\(duplicateLeafNames.formatted(.list(type: .and)))). Cambia uno para poder guardar.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                if !draft.isSingleGrade && !draft.isUndecided {
                    Section {
                        Toggle("Se evalúa distinto", isOn: Binding(
                            get: { draft.extraordinaryRoot != nil },
                            set: { draft.extraordinaryRoot = $0 ? draft.subject.root : nil }
                        ).animation())
                        if draft.extraordinaryRoot != nil, let root = Binding(unwrapping: $draft.extraordinaryRoot) {
                            NavigationLink {
                                ExtraordinaryEditorView(node: root)
                            } label: {
                                Label("Evaluación de la extraordinaria", systemImage: "arrow.uturn.backward.circle")
                            }
                        }
                    } header: {
                        Text("Extraordinaria")
                    } footer: {
                        Text(draft.extraordinaryRoot == nil
                             ? "Por defecto la extraordinaria usa esta misma evaluación. Actívalo si la guía la cambia, por ejemplo con el examen valiendo el 100 %."
                             : "Empieza como una copia de la de arriba. Una nota con el mismo nombre en las dos es la misma nota: lo que se guarda de la ordinaria pasa solo.")
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedSubjectView(subject: $draft.subject, requirements: $draft.requirements, showsCredits: library.degree.usesCredits)
                    } label: {
                        Label("Avanzado", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Opciones extra para personalizar la asignatura.")
                }
            }
            .dismissesKeyboardOnBackgroundTap()
            .navigationTitle("Editar asignatura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: save)
                        .tint(.blue)
                        .disabled(!canSave)
                        .accessibilityLabel("Guardar")
                }
            }
        }
        .environment(\.isUndecidedEvaluation, draft.subject.root.asGroup?.combination == .undecided)
        .tourPerforms(.editorOpened)
        .tourPerforms(.editorClosed, onAppear: false)
    }

    private func save() {
        var record = draft
        record.subject.root.sanitize()
        record.subject.name = record.subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.moveExamGradeDates()
        record.extraordinaryRoot?.sanitize()
        record.reassignGrades(openingIDs: openingIDs, openingExtraordinaryIDs: openingExtraordinaryIDs)
        record.requirements = record.requirements
            .map { var requirement = $0; requirement.name = requirement.name.trimmingCharacters(in: .whitespaces); return requirement }
            .filter { !$0.name.isEmpty }
        library.update(record)
        dismiss()
    }
}

private extension EnvironmentValues {
    /// True while the subject's evaluation is "Por definir": its sections only sort the notes, so
    /// weights, evaluations and minimums are hidden all the way down.
    @Entry var isUndecidedEvaluation = false
}

/// What rarely changes once a subject is set up: its credits and the grade it takes to pass.
private struct AdvancedSubjectView: View {
    @Binding var subject: Subject
    @Binding var requirements: [SubjectRequirement]
    /// Off when the study has no credits.
    let showsCredits: Bool

    var body: some View {
        Form {
            if showsCredits {
                Section {
                    Stepper(value: $subject.ectsCredits, in: 0...30, step: 0.5) {
                        LabeledContent("Créditos ECTS", value: subject.ectsCredits.formatted())
                    }
                } footer: {
                    Text("Los créditos de la asignatura: pesan en la media del expediente y cuentan en los créditos superados.")
                }
            }
            Section {
                Stepper(value: $subject.root.passThreshold, in: 0...10, step: 0.5) {
                    LabeledContent("Nota para aprobar", value: subject.root.passThreshold.formatted())
                }
            } footer: {
                Text("La nota final con la que se aprueba, sobre 10. Casi siempre un 5.")
            }
            RequirementsSection(requirements: $requirements)
        }
        .navigationTitle("Avanzado")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The editable contents of one node — reused for the subject's root and, recursively, for any
/// group inside it.
private struct NodeContentsSections: View {
    @Binding var node: Node
    var isRoot = false
    /// The root of a subject graded per term: its children are the terms.
    var isPerTerm = false
    /// The root of a scheme or of the extraordinary's evaluation (see `CalculationSection`).
    var isSubtree = false

    @Environment(\.isUndecidedEvaluation) private var isUndecided

    var body: some View {
        if isRoot || isSubtree || (!isUndecided && (node.asGroup != nil || node.asFormula != nil)) {
            CalculationSection(node: $node, isRoot: isRoot || isSubtree, isSubtree: isSubtree)
                .tourTarget(isRoot ? "editor.evaluation" : nil)
        }
        if let alternatives = Binding(unwrapping: $node.asAlternatives) {
            SchemesSections(alternatives: alternatives)
                .tourTarget(isRoot ? "editor.sections" : nil)
        } else if let group = Binding(unwrapping: $node.asGroup) {
            GroupSections(group: group, isRoot: isRoot || isSubtree, isPerTerm: isPerTerm)
                .tourTarget(isRoot ? "editor.sections" : nil)
        } else if let formula = Binding(unwrapping: $node.asFormula) {
            FormulaSections(formula: formula)
                .tourTarget(isRoot ? "editor.sections" : nil)
        } else if let grade = Binding(unwrapping: $node.asGrade) {
            if isRoot {
                // "Nota única": just the final grade, typed in the exam card of each sitting.
                GradeInputSections(grade: grade)
            } else {
                GradeTypeSection(grade: grade)
                GradeInputSections(grade: grade)
                GradeDateSection(grade: grade)
            }
        } else {
            Section {
                Text("Este tipo de componente todavía no se puede editar desde la app.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "Cómo se calcula": a weighted average, a hand-written formula or a sum of points. Switching
/// reshapes the node in place — the same parts become variables or sections — so nothing typed is
/// lost; cancelling the editor undoes it.
private struct CalculationSection: View {
    @Binding var node: Node
    /// The subject's own result (Media ponderada / Fórmula / Suma); a section inside it also offers
    /// "Examen final".
    let isRoot: Bool
    /// The root of one scheme or of the extraordinary's own evaluation: a whole grade, but only
    /// Media ponderada / Fórmula / Suma.
    var isSubtree = false

    private enum Method: Hashable {
        case group(CombinationKind)
        case formula
        case finalExam
        /// The subject is just its final grade, with no parts (e.g. only to keep the record).
        case single
        /// "Evaluación continua" or "examen único".
        case schemes

        var label: String {
            switch self {
            case .group(let kind): kind.label
            case .formula: "Fórmula"
            case .finalExam: "Examen final"
            case .single: "Nota única"
            case .schemes: "Continua o examen único"
            }
        }
    }

    /// The one grade a "Nota única" subject is made of: the final grade on its own, no sittings or dates.
    static func singleGrade() -> Node {
        .grade(Grade(name: "Nota final", category: .exam))
    }

    private var current: Method {
        if node.asAlternatives != nil { return .schemes }
        if isRoot, node.asGrade != nil { return .single }
        if !isRoot, node.isFinalExamPart { return .finalExam }
        if node.asFormula != nil { return .formula }
        return .group(node.asGroup?.combination.kind ?? .weightedAverage)
    }

    /// The methods offered for now, plus whatever an existing subject already uses (the best, the
    /// worst…) so editing it doesn't silently change it.
    private var methods: [Method] {
        var methods: [Method] = isSubtree
            ? [.group(.weightedAverage), .formula, .group(.sum)]
            : isRoot
            ? [.group(.weightedAverage), .formula, .group(.sum), .schemes, .single, .group(.undecided)]
            : [.group(.weightedAverage), .group(.sum), .formula, .finalExam]
        if !methods.contains(current) { methods.append(current) }
        return methods
    }

    private var selection: Binding<Method> {
        Binding(get: { current }, set: apply)
    }

    var body: some View {
        Section {
            Picker("Evaluación", selection: selection) {
                ForEach(methods, id: \.self) { method in
                    Text(method.label).tag(method)
                }
            }
            if let group = node.asGroup, let count = group.combination.bestOfCount {
                Stepper(
                    value: Binding(get: { count }, set: { node.asGroup?.combination = .bestOf($0) }),
                    in: 1...max(group.children.count, 1)
                ) {
                    LabeledContent("Cuántas cuentan", value: count.formatted())
                }
            }
        } footer: {
            Text(current == .single
                 ? "Solo la nota final, sin partes, pesos ni fechas: para llevar el expediente sin guardar todo lo que hiciste."
                 : current == .schemes
                 ? "Para guías con evaluación continua y examen único: cada modalidad con su evaluación. Una nota con el mismo nombre en las dos es la misma nota (el examen que comparten)."
                 : isSubtree
                 ? "Cómo se juntan sus notas en la final."
                 : current == .group(.undecided)
                 ? "Para cuando aún no sabes cómo te evalúan: apunta las notas por secciones, sin pesos ni nota final. Cuando lo sepas, elige otra evaluación y las notas se quedan donde están."
                 : isRoot
                 ? "Tipo de evaluación de la asignatura: cómo se juntan sus notas en la final."
                 : current == .finalExam
                 ? "Es el examen final: va en su propia tarjeta, con la ordinaria y la extraordinaria. Sus notas se juntan con los pesos de abajo."
                 : "Tipo de evaluación de la sección: cómo se juntan sus notas.")
        }
    }

    /// The evaluation as it was becomes "Evaluación continua", and "Examen único" is the final exam
    /// alone — the same note (same name and id), so it's typed once for both.
    static func schemes(from node: Node) -> Node {
        var continuous = node
        if case .grade(let grade) = continuous {
            continuous = .group(Engine.Group(name: grade.name, combination: .weightedAverage, children: [WeightedChild(weight: 1, node: continuous)]))
        }
        let name = continuous.title
        let minimum = continuous.minimum
        continuous.minimum = nil
        continuous.title = "Evaluación continua"
        var exam = continuous.grades.first { $0.isFinalExam == true } ?? Grade(name: "Examen único", isFinalExam: true, category: .exam)
        exam.minimum = nil
        let single = Node.group(Engine.Group(name: "Examen único", combination: .weightedAverage, children: [WeightedChild(weight: 1, node: .grade(exam))]))
        return .alternatives(Alternatives(
            name: name,
            branches: [.init(node: continuous), .init(node: single)],
            selected: 0,
            minimum: minimum ?? Minimum(threshold: 5, consequence: .fails)
        ))
    }

    /// "Examen final" marks every note inside as the exam and keeps how they're combined; leaving it
    /// clears the mark first, then reshapes like any other change.
    private func apply(_ method: Method) {
        guard method != current else { return }
        if method == .finalExam {
            node.updateGrades { $0.isFinalExam = true }
            return
        }
        if current == .finalExam {
            node.updateGrades { $0.isFinalExam = nil }
        }
        if method == .schemes {
            node = Self.schemes(from: node)
            return
        }
        if case .alternatives(let alternatives) = node {
            // Back to one evaluation: the scheme in use, with the subject's pass mark.
            let index = alternatives.selected ?? 0
            var kept = alternatives.branches.indices.contains(index) ? alternatives.branches[index].node : (alternatives.branches.first?.node ?? Self.singleGrade())
            kept.title = alternatives.name
            if let minimum = alternatives.minimum { kept.minimum = minimum }
            node = kept
            if method == current { return }
        }
        if method == .single {
            node = Self.singleGrade()
            return
        }
        if case .grade(let grade) = node {
            // From "Nota única": the grade becomes the only part, then reshapes as asked.
            node = .group(Engine.Group(name: grade.name, combination: .weightedAverage, children: [WeightedChild(weight: 1, node: node)]))
        }
        switch (node, method) {
        case (.formula(let formula), .group(let kind)):
            node = .group(formula.asGroup(kind: kind))
        case (.group(var group), .group(let kind)):
            group.combination = Engine.Group.Combination(kind: kind, bestOf: group.combination.bestOfCount ?? 1)
            // Sections added while "Por definir" have no weight: with none at all, they start equal.
            if kind == .weightedAverage || kind == .sum, !group.children.isEmpty,
               group.children.reduce(0, { $0 + $1.weight }) <= 0 {
                for index in group.children.indices { group.children[index].weight = 1 / Double(group.children.count) }
            }
            node = .group(group)
        case (.group(var group), .formula):
            // A formula can only spell out fixed weights; anything else starts from equal ones.
            if group.combination != .weightedAverage, group.combination != .sum { group.combination = .weightedAverage }
            if group.children.reduce(0, { $0 + $1.weight }) <= 0 {
                for index in group.children.indices { group.children[index].weight = 1 / Double(group.children.count) }
            }
            node = .formula(group.asFormula()
                ?? Formula(name: group.name, expression: .constant(0), variables: [:], minimum: group.minimum))
        default:
            break
        }
    }
}

/// A section title with a small green ✓ on its right edge when what's inside adds up, a red ✗
/// when it doesn't, and nothing when there's nothing to check.
private struct CheckedHeader: View {
    let title: String
    let isValid: Bool?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let isValid {
                SwiftUI.Group {
                    if isValid {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                .accessibilityLabel(isValid ? "Todo cuadra" : "Hay un error")
            }
        }
    }
}

/// Under a checked section: what's off when it doesn't add up, what the section is for otherwise.
private struct CheckFooter: View {
    let problem: String?
    let hint: String

    var body: some View {
        if let problem {
            Text(problem).foregroundStyle(.red)
        } else {
            Text(hint)
        }
    }
}

private struct GroupSections: View {
    @Binding var group: Engine.Group
    var isRoot = false
    var isPerTerm = false

    @Environment(\.isUndecidedEvaluation) private var isUndecided

    private var totalWeight: Double { group.children.reduce(0) { $0 + $1.weight } }

    /// A weighted average should share out exactly 100 %, and the subject's own sum exactly its 10
    /// points. A sum inside another part can add up to anything: its parent scales it.
    /// `nil` when there's nothing to check, `.some(nil)` when it adds up, else what's off.
    private var check: String?? {
        guard !group.children.isEmpty, !isUndecided else { return nil }
        let isOff = abs(totalWeight - 1) > 0.001
        switch group.combination {
        case .weightedAverage:
            return .some(isOff ? "Los porcentajes suman \(formatted(totalWeight * 100))\u{00A0}%; deberían sumar 100\u{00A0}%." : nil)
        case .sum where isRoot:
            return .some(isOff ? "Los puntos suman \(formatted(totalWeight * 10)); deberían sumar 10." : nil)
        default:
            return nil
        }
    }

    var body: some View {
        Section {
            ForEach($group.children) { $child in
                NavigationLink {
                    ComponentEditorView(child: $child, combination: group.combination, onDelete: {
                        group.children.removeAll { $0.id == child.id }
                    })
                } label: {
                    ComponentRow(title: child.node.title, subtitle: child.node.rowSubtitle, value: isUndecided ? "" : share(of: child))
                }
            }
            .onDelete { group.children.remove(atOffsets: $0) }

            // Opens the new section straight away; it only joins the list once its required
            // fields are filled and it's confirmed. Going back discards it.
            NavigationLink {
                NewSectionView(child: newChild(), combination: group.combination) { group.children.append($0) }
            } label: {
                Label("Añadir", systemImage: "plus.circle.fill")
                    .foregroundStyle(.tint)
            }
        } header: {
            CheckedHeader(title: isPerTerm ? "Periodos" : isRoot ? "Secciones" : "Subsecciones", isValid: check.map { $0 == nil })
        } footer: {
            CheckFooter(problem: check ?? nil, hint: isUndecided
                ? (isRoot
                   ? "Las secciones solo ordenan tus notas: no tienen peso ni cuentan para nada."
                   : "Las notas en las que se divide esta sección.")
                : isPerTerm
                ? "Cada periodo con su propia evaluación y su peso en la nota final."
                : isRoot
                ? "Personaliza las secciones en las que se divide la nota final."
                : "Personaliza las subsecciones en las que se divide esta sección.")
        }
    }

    /// What a section counts for, in the group's own terms: its percentage or its points.
    private func share(of child: WeightedChild) -> String {
        switch group.combination {
        case .sum:
            let points = child.weight * 10
            return "\(formatted(points)) \(abs(points - 1) < 1e-9 ? "pt" : "pts")"
        case .weightedAverage:
            return "\(formatted(child.weight * 100))\u{00A0}%"
        case .max, .min, .bestOf, .undecided:
            return ""
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// A single note called "Nueva sección", taking whatever weight (or points) is still
    /// unassigned so adding one rarely leaves the total off.
    private func newChild() -> WeightedChild {
        let fills = group.combination == .weightedAverage || group.combination == .sum
        return WeightedChild(
            weight: fills ? max(0, 1 - totalWeight) : 0,
            node: asExamIfNeeded(.grade(Grade(name: uniqueName("Nueva sección"))))
        )
    }

    /// A note added to the final exam is part of the exam too, or the part would stop being one.
    private func asExamIfNeeded(_ node: Node) -> Node {
        guard Node.group(group).isFinalExamPart else { return node }
        var node = node
        node.updateGrades { $0.isFinalExam = true }
        return node
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(group.children.map(\.node.title))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }
}

private struct FormulaSections: View {
    @Binding var formula: Formula

    @State private var text = ""
    @State private var parseError: String?

    private var orderedKeys: [String] {
        let used = formula.expression.variableOrder.filter { formula.variables[$0] != nil }
        return used + formula.variables.keys.sorted().filter { !used.contains($0) }
    }

    /// The formula reads, and no mix of grades takes the result below 0 or above 10.
    /// What's off, or `nil` when it's fine.
    private var problem: String? {
        if parseError != nil { return "La fórmula tiene un error." }
        let range = formula.resultRange
        guard range.lowerBound < -0.001 || range.upperBound > 10.001 else { return nil }
        return "La fórmula puede dar de \(formatted(range.lowerBound)) a \(formatted(range.upperBound)); debería quedarse entre 0 y 10."
    }

    var body: some View {
        Section {
            TextField("Fórmula", text: $text, axis: .vertical)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: text) { apply() }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(orderedKeys, id: \.self) { key in
                        InsertChip(label: key, bold: true) { text += key }
                    }
                    ForEach(["+", "-", "*", "/", "(", ")", ";", ">="], id: \.self) { token in
                        InsertChip(label: token) { text += " \(token) " }
                    }
                    ForEach(["min(", "max(", "si("], id: \.self) { token in
                        InsertChip(label: token) { text += token }
                    }
                }
            }
            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Fórmula")
        } footer: {
            Text("Escríbela como en la guía, con las letras de las variables de abajo: por ejemplo «0,4 * P + 0,6 * E». Los decimales llevan coma y los argumentos se separan con «;»: «min(a; b)», «max(a; b)» y «si(E >= 4; entonces; si no)».")
        }
        .onAppear { text = formula.expression.source }

        Section {
            ForEach(orderedKeys, id: \.self) { key in
                NavigationLink {
                    FormulaVariableEditor(key: key, formula: $formula, onRenameKey: renameKey)
                } label: {
                    ComponentRow(
                        title: "\(key) · \(formula.variables[key]?.title ?? key)",
                        subtitle: formula.variables[key]?.rowSubtitle ?? "",
                        value: share(of: key)
                    )
                }
                .deleteDisabled(formula.expression.variableOrder.contains(key))
            }
            .onDelete { offsets in
                for key in offsets.map({ orderedKeys[$0] }) where !formula.expression.variableOrder.contains(key) {
                    formula.variables[key] = nil
                }
            }
            Button("Añadir variable", systemImage: "plus.circle.fill", action: addVariable)
        } header: {
            CheckedHeader(title: "Variables", isValid: problem == nil)
        } footer: {
            CheckFooter(problem: problem, hint: "Personaliza las variables con las que se calcula la nota final.")
        }
    }

    /// How much of the final grade a variable can account for, estimated from the formula: one
    /// percentage for a fixed weight, a range when its weight moves with other grades.
    private func share(of key: String) -> String {
        let range = formula.contributionRange(of: key)
        let low = max(0, range.lowerBound) * 10, high = max(0, range.upperBound) * 10
        return high - low < 0.5 ? "\(formatted(high))\u{00A0}%" : "\(formatted(low))–\(formatted(high))\u{00A0}%"
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Applies the text as the formula as soon as it reads; until it does, the last good one stays.
    private func apply() {
        do {
            formula.expression = try Engine.Expression.parse(text, variables: Set(formula.variables.keys))
            parseError = nil
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func renameKey(_ old: String, _ new: String) {
        guard old != new, let variable = formula.variables[old] else { return }
        formula.variables[old] = nil
        formula.variables[new] = variable
        formula.expression = formula.expression.renamingVariable(old, to: new)
        text = formula.expression.source
    }

    private func addVariable() {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        let key = letters.first { formula.variables[$0] == nil } ?? "V\(formula.variables.count + 1)"
        let taken = Set(formula.variables.values.map(\.title))
        let name = taken.contains("Nota nueva") ? ((2...).lazy.map { "Nota nueva \($0)" }.first { !taken.contains($0) }!) : "Nota nueva"
        formula.variables[key] = .grade(Grade(name: name, isFinalExam: Node.formula(formula).isFinalExamPart ? true : nil))
    }
}

private struct InsertChip: View {
    let label: String
    var bold = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospaced().weight(bold ? .bold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// One variable of a formula: its letter, its name and everything about how its grade is given.
private struct FormulaVariableEditor: View {
    let key: String
    @Binding var formula: Formula
    let onRenameKey: (String, String) -> Void

    @State private var keyText: String
    @State private var keyError: String?

    init(key: String, formula: Binding<Formula>, onRenameKey: @escaping (String, String) -> Void) {
        self.key = key
        _formula = formula
        self.onRenameKey = onRenameKey
        _keyText = State(initialValue: key)
    }

    private var node: Binding<Node> {
        Binding(
            get: { formula.variables[key] ?? .grade(Grade(name: key)) },
            set: { formula.variables[key] = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Variable") {
                    TextField("Letra", text: $keyText)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospaced().bold())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                NameField(node: node)
            } footer: {
                if let keyError {
                    Label(keyError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text("La letra es como se llama en la fórmula.")
                }
            }

            if let grade = Binding(unwrapping: node.asGrade) {
                GradeTypeSection(grade: grade)
            }
            if node.wrappedValue.asGrade != nil || node.wrappedValue.isGroupOfGrades {
                NoteCountSection(node: node)
            }
            if node.wrappedValue.asGroup != nil || node.wrappedValue.asFormula != nil {
                MinimumSection(node: node)
                NodeContentsSections(node: node)
            } else if let grade = Binding(unwrapping: node.asGrade) {
                GradeInputSections(grade: grade)
                MinimumSection(node: node)
                GradeDateSection(grade: grade)
            }
        }
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: keyText) { keyError = validation(keyText) }
        .onDisappear {
            let trimmed = keyText.trimmingCharacters(in: .whitespaces)
            if validation(trimmed) == nil { onRenameKey(key, trimmed) }
        }
    }

    /// A letter or short name that the formula can read: starts with a letter, no spaces, not
    /// another variable and not a function name. `nil` when it's fine (or unchanged).
    private func validation(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name == key { return nil }
        guard let first = name.first, first.isLetter, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return "Usa letras y números, empezando por una letra."
        }
        if ["min", "max", "mín", "máx", "si", "if"].contains(name.lowercased()) { return "«\(name)» es una función de la fórmula." }
        if formula.variables[name] != nil { return "Ya hay una variable «\(name)»." }
        return nil
    }
}

/// One part of a group: its name and weight, plus either its scale (a grade) or its own parts
/// (a nested group).
private struct ComponentEditorView: View {
    @Binding var child: WeightedChild
    /// How the parent combines its parts: a sum counts each in points, anything else in percent.
    let combination: Engine.Group.Combination
    /// Removes this section from its parent; called once the screen has gone, so nothing here
    /// reads the removed child.
    var onDelete: () -> Void = {}
    /// Set while the section is being created: a ✓ adds it (once its required fields are filled)
    /// instead of the delete button.
    var onAdd: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isUndecidedEvaluation) private var isUndecided
    @State private var isDeleting = false

    private var isPoints: Bool { combination == .sum }

    /// Named, and every note inside has its type.
    private var isComplete: Bool {
        !child.node.title.trimmingCharacters(in: .whitespaces).isEmpty
            && child.node.grades.allSatisfy { GradeType($0) != nil }
    }

    var body: some View {
        Form {
            Section {
                NameField(node: $child.node)
            } footer: {
                Text("Nombre de la sección. Toca para cambiarlo.")
            }

            if let grade = Binding(unwrapping: $child.node.asGrade) {
                GradeTypeSection(grade: grade)
            }

            Section {
                if !isUndecided {
                    LabeledContent(isPoints ? "Puntos" : "Peso") {
                        HStack(spacing: 4) {
                            TextField("0", value: Binding(
                                get: { child.weight * (isPoints ? 10 : 100) },
                                set: { child.weight = $0 / (isPoints ? 10 : 100) }
                            ), format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text(isPoints ? "pts" : "%").foregroundStyle(.secondary)
                        }
                    }
                }
                if child.node.asGrade != nil || child.node.isGroupOfGrades {
                    NoteCountRow(node: $child.node)
                }
            } footer: {
                Text(isUndecided
                     ? "En cuántas subsecciones se divide esta sección."
                     : isPoints
                     ? "Los puntos que da esta sección y en cuántas subsecciones se divide."
                     : "Lo que cuenta esta sección en la nota y en cuántas subsecciones se divide.")
            }

            if child.node.asGroup != nil || child.node.asFormula != nil {
                if !isUndecided { MinimumSection(node: $child.node) }
                RecoverySection(node: $child.node)
                NodeContentsSections(node: $child.node)
            } else if let grade = Binding(unwrapping: $child.node.asGrade) {
                GradeInputSections(grade: grade)
                if !isUndecided { MinimumSection(node: $child.node) }
                RecoverySection(node: $child.node)
                GradeDateSection(grade: grade)
            }

            if onAdd == nil {
                Section {
                    Button(role: .destructive) {
                        isDeleting = true
                        dismiss()
                    } label: {
                        Label("Eliminar sección", systemImage: "trash")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                }
            }
        }
        .navigationTitle(child.node.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onAdd {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        onAdd()
                        dismiss()
                    }
                    .tint(.blue)
                    .disabled(!isComplete)
                }
            }
        }
        .onDisappear { if isDeleting { onDelete() } }
    }
}

/// How many notes make up a part: one, or several averaged (two lab practicals, ten quizzes…).
/// Changing it reshapes the part in place instead of deleting and re-creating it.
private struct NoteCountSection: View {
    @Binding var node: Node

    var body: some View {
        let count = node.noteCount
        Section {
            NoteCountRow(node: $node)
        } footer: {
            Text(count == 1
                 ? "Una sola nota. Súbelo si en clase hay varias (por ejemplo, dos prácticas): la parte será su media. La nota ya puesta de esta parte se borra."
                 : "La parte se calcula con estas \(count) notas. Más abajo puedes cambiar el nombre y el peso de cada una.")
        }
    }
}

/// A section being added: edited on its own copy and handed back only when confirmed.
private struct NewSectionView: View {
    @State private var child: WeightedChild
    let combination: Engine.Group.Combination
    let onAdd: (WeightedChild) -> Void

    init(child: WeightedChild, combination: Engine.Group.Combination, onAdd: @escaping (WeightedChild) -> Void) {
        _child = State(initialValue: child)
        self.combination = combination
        self.onAdd = onAdd
    }

    var body: some View {
        ComponentEditorView(child: $child, combination: combination, onAdd: {
            onAdd(child)
        })
    }
}

/// "Subsecciones" with glass − / + buttons: 1 is a single grade, more turns the part into
/// that many equal notes (see `Node.resizeNotes`).
private struct NoteCountRow: View {
    @Binding var node: Node

    var body: some View {
        let count = node.noteCount
        LabeledContent("Subsecciones") {
            HStack(spacing: 10) {
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                StepButton(systemImage: "minus", label: "Una menos", isEnabled: count > 1) { node.resizeNotes(to: count - 1) }
                StepButton(systemImage: "plus", label: "Una más", isEnabled: count < 20) { node.resizeNotes(to: count + 1) }
            }
            .animation(.snappy, value: count)
        }
    }
}

/// A round glass − / + button, as in "Subsecciones".
struct StepButton: View {
    let systemImage: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// "Modalidades": one row per scheme, opening its own evaluation, and whether the student picks
/// one or the best counts.
private struct SchemesSections: View {
    @Binding var alternatives: Alternatives

    var body: some View {
        Section {
            ForEach(alternatives.branches.indices, id: \.self) { index in
                NavigationLink {
                    SchemeEditorView(node: $alternatives.branches[index].node)
                } label: {
                    ComponentRow(title: alternatives.branches[index].node.title, subtitle: alternatives.branches[index].node.rowSubtitle, value: "")
                }
            }
        } header: {
            Text("Modalidades")
        } footer: {
            Text("Toca una para cambiar sus secciones y pesos.")
        }

        Section {
            Toggle("Cuenta la mejor de las dos", isOn: $alternatives.pickBest)
            if !alternatives.pickBest {
                Picker("Tu modalidad", selection: Binding(get: { alternatives.selected ?? 0 }, set: { alternatives.selected = $0 })) {
                    ForEach(alternatives.branches.indices, id: \.self) { index in
                        Text(alternatives.branches[index].node.title).tag(index)
                    }
                }
            }
        } footer: {
            Text(alternatives.pickBest
                 ? "La nota final es la mejor de las dos modalidades que apruebe. Apunta todas tus notas y Grade calcula las dos."
                 : "La que vas a seguir: es la que cuenta. Se puede cambiar cuando quieras, también desde «…» en la asignatura.")
        }
    }
}

/// One scheme's evaluation: its name, then the same sections as a subject.
private struct SchemeEditorView: View {
    @Binding var node: Node

    var body: some View {
        Form {
            Section {
                NameField(node: $node)
            } footer: {
                Text("Nombre de la modalidad, como en la guía.")
            }
            NodeContentsSections(node: $node, isSubtree: true)
        }
        .navigationTitle(node.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The extraordinary sitting's own evaluation, when the guide changes it.
private struct ExtraordinaryEditorView: View {
    @Binding var node: Node

    var body: some View {
        Form {
            NodeContentsSections(node: $node, isSubtree: true)
        }
        .navigationTitle("Extraordinaria")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "En la extraordinaria": whether a section's grade carries over, is taken again, carries over
/// only from a grade, or can't be taken again at all.
private struct RecoverySection: View {
    @Binding var node: Node

    private enum Choice: Hashable, CaseIterable {
        case inherited, kept, retaken, keptFrom, locked

        var label: String {
            switch self {
            case .inherited: "Como siempre"
            case .kept: "Se guarda"
            case .retaken: "Se repite"
            case .keptFrom: "Se guarda si llegas a…"
            case .locked: "No se puede recuperar"
            }
        }
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch node.recovery {
                case nil: .inherited
                case .recoverableInExtraordinary: .retaken
                case .notRecoverable: .locked
                case .savedIfAtLeast: .keptFrom
                default: .kept
                }
            },
            set: { choice in
                switch choice {
                case .inherited: node.recovery = nil
                case .kept: node.recovery = .savedForExtraordinary
                case .retaken: node.recovery = .recoverableInExtraordinary
                case .keptFrom: node.recovery = .savedIfAtLeast(node.scaleMax / 2)
                case .locked: node.recovery = .notRecoverable
                }
            }
        )
    }

    private var threshold: Binding<Double> {
        Binding(
            get: { if case .savedIfAtLeast(let value)? = node.recovery { value } else { node.scaleMax / 2 } },
            set: { node.recovery = .savedIfAtLeast($0.isFinite ? $0 : node.scaleMax / 2) }
        )
    }

    var body: some View {
        Section {
            Picker("En la extraordinaria", selection: choice) {
                ForEach(Choice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if case .savedIfAtLeast? = node.recovery {
                LabeledContent("Se guarda desde") {
                    HStack(spacing: 4) {
                        TextField("5", value: threshold, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("/ \(node.scaleMax.formatted(.number.precision(.fractionLength(0...2))))").foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("Si su nota de la ordinaria pasa a la extraordinaria. «Como siempre»: se guarda todo menos el examen final, salvo que la sección de arriba diga otra cosa. «No se puede recuperar»: se queda la de la ordinaria y no se cambia.")
        }
    }
}

/// "Requisitos": conditions with no grade, like compulsory attendance; one not met fails.
private struct RequirementsSection: View {
    @Binding var requirements: [SubjectRequirement]

    var body: some View {
        Section {
            ForEach($requirements) { $requirement in
                TextField("Asistencia mínima del 80 %", text: $requirement.name)
            }
            .onDelete { requirements.remove(atOffsets: $0) }
            Button("Añadir requisito", systemImage: "plus.circle.fill") {
                requirements.append(SubjectRequirement(name: ""))
            }
        } header: {
            Text("Requisitos")
        } footer: {
            Text("Condiciones sin nota que hay que cumplir para aprobar, como la asistencia o entregar todas las prácticas. Se marcan en la asignatura; si una no se cumple, no apruebas.")
        }
    }
}

private struct NameField: View {
    @Binding var node: Node

    var body: some View {
        InlineField("Nombre") {
            TextField("Nombre", text: $node.title)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(.secondary)
        }
    }
}

/// "Fecha" with nothing set until one is picked: "Añadir" puts today 23:59 (the usual deadline for a
/// hand-in) and shows the picker; the ✕ takes it away again.
private struct DateRow: View {
    @Binding var date: Date?

    var body: some View {
        LabeledContent("Fecha") {
            if let date = Binding(unwrapping: $date) {
                HStack(spacing: 8) {
                    DatePicker("Fecha", selection: date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    Button {
                        self.date = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Quitar fecha")
                }
            } else {
                Button("Añadir") { date = Self.defaultDate }
            }
        }
    }

    private static var defaultDate: Date {
        Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: .now) ?? .now
    }
}

/// What a grade is — Trabajo, Control, Examen parcial or Examen final. Required: a new section
/// starts with none and the subject can't be saved until it has one. "Examen final" is also what
/// marks the grade as the exam (its own card, a date per sitting).
private struct GradeTypeSection: View {
    @Binding var grade: Grade

    var body: some View {
        let type = GradeType(grade)
        Section {
            LabeledContent("Tipo") {
                Menu {
                    Picker("Tipo", selection: Binding(get: { type }, set: { $0?.apply(to: &grade) })) {
                        ForEach(GradeType.allCases) { type in
                            Text(type.label).tag(GradeType?.some(type))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(type?.label ?? "Elegir")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(type == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
        } footer: {
            Text(type == nil
                 ? "Obligatorio: elige qué es esta nota."
                 : "Es el color con el que sale en el Calendario y lo que filtra.")
        }
    }
}

enum GradeType: CaseIterable, Identifiable {
    case work, quiz, partialExam, finalExam

    var id: Self { self }

    var label: String {
        switch self {
        case .work: "Trabajo"
        case .quiz: "Control"
        case .partialExam: "Examen parcial"
        case .finalExam: "Examen final"
        }
    }

    /// `nil` while the grade has no type yet.
    init?(_ grade: Grade) {
        if grade.isFinalExam == true { self = .finalExam; return }
        switch grade.category {
        case .work: self = .work
        case .quiz: self = .quiz
        case .exam: self = .partialExam
        case nil: return nil
        }
    }

    func apply(to grade: inout Grade) {
        switch self {
        case .work: grade.category = .work
        case .quiz: grade.category = .quiz
        case .partialExam, .finalExam: grade.category = .exam
        }
        grade.isFinalExam = self == .finalExam ? true : nil
    }
}

/// How the grade is given: in points out of a maximum, or with letters and what each is worth.
private struct GradeInputSections: View {
    @Binding var grade: Grade

    private static let defaultLetters = [
        LetterGrade(letter: "A", value: 10),
        LetterGrade(letter: "B", value: 7.5),
        LetterGrade(letter: "C", value: 5),
        LetterGrade(letter: "D", value: 2.5),
        LetterGrade(letter: "E", value: 0),
    ]

    private var isLetters: Bool {
        if case .letters = grade.inputStyle { true } else { false }
    }

    /// Percent isn't offered any more; a grade still set to it shows (and is typed) as points.
    private var style: Binding<InputStyleKind> {
        Binding(
            get: { isLetters ? .letters : .points },
            set: { kind in
                switch kind {
                case .points: grade.inputStyle = nil
                case .letters:
                    if !isLetters { grade.inputStyle = .letters(Self.defaultLetters) }
                }
            }
        )
    }

    private var letters: Binding<[LetterGrade]> {
        Binding(
            get: { if case .letters(let scale) = grade.inputStyle { scale } else { [] } },
            set: { grade.inputStyle = .letters($0) }
        )
    }

    var body: some View {
        Section {
            Picker("Cómo se evalúa", selection: style) {
                ForEach(InputStyleKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            if !isLetters {
                ScaleField(scaleMax: $grade.scaleMax)
            }
        } footer: {
            Text(isLetters
                 ? "Te la dan con letras; abajo pones lo que vale cada una."
                 : "Te la dan en puntos, sobre esta nota máxima.")
        }

        if isLetters {
            Section {
                ForEach(letters) { $letter in
                    HStack {
                        TextField("Letra", text: $letter.letter)
                            .font(.headline)
                        Spacer()
                        TextField("0", value: $letter.value, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("/ 10").foregroundStyle(.secondary)
                    }
                }
                .onDelete { letters.wrappedValue.remove(atOffsets: $0) }
                Button("Añadir letra", systemImage: "plus") {
                    letters.wrappedValue.append(LetterGrade(letter: "", value: 0))
                }
            } header: {
                Text("Equivalencia de las letras")
            } footer: {
                Text("Lo que vale cada letra, sobre 10.")
            }
        }
    }
}

/// The due date, last on the screen. The final exam has one per sitting instead, set from "Fechas".
private struct GradeDateSection: View {
    @Binding var grade: Grade

    var body: some View {
        // The final exam's dates belong to its sittings (the subject's «Fechas»), not to the note.
        if grade.isFinalExam != true {
            Section {
                DateRow(date: $grade.date)
            } footer: {
                Text("Si tiene fecha, aparece en el Calendario.")
            }
        }
    }
}

private enum InputStyleKind: String, CaseIterable, Identifiable {
    case points, letters

    var id: Self { self }

    var label: String {
        switch self {
        case .points: "Puntos"
        case .letters: "Letras"
        }
    }
}

/// "Nota mínima" (optional, on the section's own scale) and, once there is one, "Consecuencia":
/// what missing it does — the dependencies between parts that a syllabus spells out.
private struct MinimumSection: View {
    @Binding var node: Node

    private var threshold: Binding<Double?> {
        Binding(
            get: { node.minimum?.threshold },
            set: { value in
                if let value {
                    node.minimum = Minimum(threshold: value, consequence: node.minimum?.consequence ?? .fails)
                } else {
                    node.minimum = nil
                }
            }
        )
    }

    private var consequence: Binding<ConsequenceKind> {
        Binding(
            get: { node.minimum.map { ConsequenceKind($0.consequence) } ?? .fails },
            set: { kind in
                guard let minimum = node.minimum else { return }
                node.minimum = Minimum(threshold: minimum.threshold, consequence: kind.consequence(keeping: minimum.consequence))
            }
        )
    }

    private var cap: Binding<Double> {
        Binding(
            get: { if case .capAt(let cap)? = node.minimum?.consequence { cap } else { ConsequenceKind.defaultCap } },
            set: { cap in
                guard let minimum = node.minimum else { return }
                node.minimum = Minimum(threshold: minimum.threshold, consequence: .capAt(cap))
            }
        )
    }

    var body: some View {
        let max = node.scaleMax.formatted(.number.precision(.fractionLength(0...2)))
        let kind = node.minimum.map { ConsequenceKind($0.consequence) }
        Section {
            LabeledContent("Nota mínima") {
                HStack(spacing: 4) {
                    TextField("Ninguna", value: threshold, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("/ \(max)").foregroundStyle(.secondary)
                }
            }
            if let kind {
                LabeledContent("Consecuencia") {
                    Menu {
                        Picker("Consecuencia", selection: consequence) {
                            ForEach(ConsequenceKind.allCases) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(kind.label)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                if kind == .capAt {
                    LabeledContent("Nota tope") {
                        HStack(spacing: 4) {
                            TextField("4,5", value: cap, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("/ 10").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } footer: {
            Text(kind?.explanation ?? "Opcional. Lo que hay que sacar como mínimo en esta sección, si la guía lo pide.")
        }
    }
}

/// `Minimum.Consequence` without the cap, for a `Picker`.
private enum ConsequenceKind: CaseIterable, Identifiable {
    case fails, capAt, voids, doesNotAverage, sendsToExtraordinary

    static let defaultCap = 4.5

    var id: Self { self }

    init(_ consequence: Minimum.Consequence) {
        switch consequence {
        case .fails: self = .fails
        case .capAt: self = .capAt
        case .voids: self = .voids
        case .doesNotAverage: self = .doesNotAverage
        case .sendsToExtraordinary: self = .sendsToExtraordinary
        }
    }

    /// The consequence this picks, keeping the cap if it already was one.
    func consequence(keeping current: Minimum.Consequence) -> Minimum.Consequence {
        switch self {
        case .fails: return .fails
        case .capAt:
            if case .capAt = current { return current }
            return .capAt(Self.defaultCap)
        case .voids: return .voids
        case .doesNotAverage: return .doesNotAverage
        case .sendsToExtraordinary: return .sendsToExtraordinary
        }
    }

    var label: String {
        switch self {
        case .fails: "Suspendes la asignatura"
        case .capAt: "Limita la nota final"
        case .voids: "Se anula la sección"
        case .doesNotAverage: "No hace media"
        case .sendsToExtraordinary: "Vas a la extraordinaria"
        }
    }

    var explanation: String {
        switch self {
        case .fails: "Si no llegas, suspendes aunque la media dé para aprobar."
        case .capAt: "Si no llegas, la nota final no pasa de la nota tope aunque la media dé más."
        case .voids: "Si no llegas, esta sección cuenta como un 0."
        case .doesNotAverage: "Si no llegas, esta sección no cuenta y las demás se reparten su peso."
        case .sendsToExtraordinary: "Si no llegas, suspendes la ordinaria y esta sección se vuelve a hacer en la extraordinaria."
        }
    }
}

private struct ScaleField: View {
    @Binding var scaleMax: Double

    var body: some View {
        LabeledContent("Nota máxima") {
            TextField("10", value: $scaleMax, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// One section or variable in the list: its name, what it's made of underneath, and what it counts
/// for on the right.
private struct ComponentRow: View {
    let title: String
    let subtitle: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
