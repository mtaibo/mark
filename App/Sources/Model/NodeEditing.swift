import Engine
import Foundation

/// Read/write views onto `Node`'s cases, so editors can bind straight into the tree
/// (`Binding($node.asGroup)`) instead of switching and reassembling by hand at every level.
extension Node {
    var title: String {
        get {
            switch self {
            case .grade(let grade): grade.name
            case .group(let group): group.name
            case .alternatives(let alternatives): alternatives.name
            case .bonus(let bonus): bonus.name
            case .requirement(let requirement): requirement.name
            case .formula(let formula): formula.name
            }
        }
        set {
            switch self {
            case .grade(var grade): grade.name = newValue; self = .grade(grade)
            case .group(var group): group.name = newValue; self = .group(group)
            case .alternatives(var alternatives): alternatives.name = newValue; self = .alternatives(alternatives)
            case .bonus(var bonus): bonus.name = newValue; self = .bonus(bonus)
            case .requirement(var requirement): requirement.name = newValue; self = .requirement(requirement)
            case .formula(var formula): formula.name = newValue; self = .formula(formula)
            }
        }
    }

    var asGrade: Grade? {
        get { if case .grade(let grade) = self { grade } else { nil } }
        set { if let newValue { self = .grade(newValue) } }
    }

    var asGroup: Group? {
        get { if case .group(let group) = self { group } else { nil } }
        set { if let newValue { self = .group(newValue) } }
    }

    var asFormula: Formula? {
        get { if case .formula(let formula) = self { formula } else { nil } }
        set { if let newValue { self = .formula(newValue) } }
    }

    /// Every grade under this node that has a due date, as (leaf name, date).
    var datedGrades: [(name: String, date: Date)] {
        switch self {
        case .grade(let grade): grade.date.map { [(grade.name, $0)] } ?? []
        case .group(let group): group.children.flatMap(\.node.datedGrades)
        case .formula(let formula): formula.variables.values.flatMap(\.datedGrades)
        case .alternatives(let alternatives): alternatives.branches.flatMap(\.node.datedGrades)
        case .bonus, .requirement: []
        }
    }

    /// The name of the part that gets the exam card ("Prueba objetiva"), if any — used wherever its
    /// sittings' dates are shown so they read the same everywhere.
    var examTitle: String? {
        switch self {
        case .group(let group): group.children.first { $0.node.isFinalExamPart }?.node.title
        case .formula(let formula):
            formula.expression.variableOrder.compactMap { formula.variables[$0] }.first(where: \.isFinalExamPart)?.title
                ?? formula.variables.keys.sorted().compactMap { formula.variables[$0] }.first(where: \.isFinalExamPart)?.title
        default: isFinalExamPart ? title : nil
        }
    }

    /// A group made only of plain grades: what "several notes" in the editor turns a part into.
    var isGroupOfGrades: Bool {
        guard case .group(let group) = self else { return false }
        return !group.children.isEmpty && group.children.allSatisfy { $0.node.asGrade != nil }
    }

    /// 1 for a single grade, the number of notes for a group of grades.
    var noteCount: Int {
        switch self {
        case .group(let group): group.children.count
        default: 1
        }
    }

    /// Turns a single grade into a group of `count` equal notes, a group of notes into one with
    /// more or fewer, or back into a single grade at 1 — keeping how the notes are given. A grade's
    /// minimum moves to the group so it still applies to the whole part.
    mutating func resizeNotes(to count: Int) {
        let count = Swift.max(count, 1)
        switch self {
        case .grade(let grade):
            guard count > 1 else { return }
            var template = grade
            template.minimum = nil
            template.date = nil
            let children = (1...count).map { number -> WeightedChild in
                var note = template
                note.name = "\(grade.name) \(number)"
                return WeightedChild(weight: 1 / Double(count), node: .grade(note))
            }
            self = .group(Group(name: grade.name, combination: .weightedAverage, children: children, minimum: grade.minimum))
        case .group(var group):
            guard isGroupOfGrades, let first = group.children.first?.node.asGrade else { return }
            if count == 1 {
                var single = first
                single.name = group.name
                single.minimum = group.minimum
                single.date = nil
                self = .grade(single)
                return
            }
            let weights = group.children.map(\.weight)
            let equal = Set(weights).count <= 1
            let newWeight = weights.reduce(0, +) / Double(weights.count)
            while group.children.count > count { group.children.removeLast() }
            var taken = Set(group.children.map(\.node.title))
            while group.children.count < count {
                var note = first
                note.date = nil
                note.name = (1...).lazy.map { "\(group.name) \($0)" }.first { !taken.contains($0) }!
                taken.insert(note.name)
                group.children.append(WeightedChild(weight: newWeight, node: .grade(note)))
            }
            if equal {
                for index in group.children.indices { group.children[index].weight = 1 / Double(count) }
            }
            self = .group(group)
        default:
            break
        }
    }

    /// What happens to this node in the extraordinary sitting, on whichever node can carry it.
    var recovery: Recovery? {
        get {
            switch self {
            case .grade(let grade): grade.recovery
            case .group(let group): group.recovery
            case .formula(let formula): formula.recovery
            default: nil
            }
        }
        set {
            switch self {
            case .grade(var grade): grade.recovery = newValue; self = .grade(grade)
            case .group(var group): group.recovery = newValue; self = .group(group)
            case .formula(var formula): formula.recovery = newValue; self = .formula(formula)
            default: break
            }
        }
    }

    /// The innermost rule on the way to `leaf` (the note's own, else its section's, and so on up),
    /// with the node that carries it.
    func recoveryRule(for leaf: String) -> (recovery: Recovery, node: Node)? {
        guard let path = path(to: leaf) else { return nil }
        for node in path.reversed() {
            if let recovery = node.recovery { return (recovery, node) }
        }
        return nil
    }

    /// The nodes from this one down to the grade named `leaf`, both included.
    func path(to leaf: String) -> [Node]? {
        switch self {
        case .grade(let grade):
            return grade.name == leaf ? [self] : nil
        case .group(let group):
            for child in group.children { if let path = child.node.path(to: leaf) { return [self] + path } }
        case .formula(let formula):
            for key in formula.variables.keys.sorted() { if let path = formula.variables[key]?.path(to: leaf) { return [self] + path } }
        case .alternatives(let alternatives):
            for branch in alternatives.branches { if let path = branch.node.path(to: leaf) { return [self] + path } }
        case .bonus, .requirement:
            break
        }
        return nil
    }

    var asAlternatives: Alternatives? {
        get { if case .alternatives(let alternatives) = self { alternatives } else { nil } }
        set { if let newValue { self = .alternatives(newValue) } }
    }

    /// Gives every note an id of its own: one without (an older file, a template) or repeating
    /// an earlier one's (a copied section) gets a new one. In tree order, so the first copy keeps it.
    mutating func identifyGrades() {
        var seen: Set<UUID> = []
        updateGrades { grade in
            if let id = grade.id, seen.insert(id).inserted { return }
            let id = UUID()
            grade.id = id
            seen.insert(id)
        }
    }

    /// Each note's id by its name (the first note, if a name repeats).
    var gradeIDsByName: [String: UUID] {
        Dictionary(grades.compactMap { grade in grade.id.map { (grade.name, $0) } }) { first, _ in first }
    }

    /// Each note's name by its id (the first note, if an id repeats).
    var gradeNamesByID: [UUID: String] {
        Dictionary(grades.compactMap { grade in grade.id.map { ($0, grade.name) } }) { first, _ in first }
    }

    /// Every grade and bonus under this node renamed by `transform`.
    mutating func renameLeaves(_ transform: (String) -> String) {
        switch self {
        case .grade(var grade):
            grade.name = transform(grade.name)
            self = .grade(grade)
        case .bonus(var bonus):
            bonus.name = transform(bonus.name)
            self = .bonus(bonus)
        case .group(var group):
            for index in group.children.indices { group.children[index].node.renameLeaves(transform) }
            self = .group(group)
        case .formula(var formula):
            for key in formula.variables.keys { formula.variables[key]?.renameLeaves(transform) }
            self = .formula(formula)
        case .alternatives(var alternatives):
            for index in alternatives.branches.indices { alternatives.branches[index].node.renameLeaves(transform) }
            self = .alternatives(alternatives)
        case .requirement:
            break
        }
    }

    /// Brings back into range what a form can leave out of it — an empty, negative or non-numeric
    /// weight, a scale of 0 — so the engine never divides by it or averages a negative share.
    mutating func sanitize() {
        if let minimum, !minimum.threshold.isFinite {
            self.minimum = nil
        } else if case .capAt(let cap)? = minimum?.consequence, !cap.isFinite {
            minimum?.consequence = .capAt(4.5)
        }
        switch self {
        case .grade(var grade):
            if !(grade.scaleMax.isFinite && grade.scaleMax > 0) { grade.scaleMax = 10 }
            if case .letters(var letters) = grade.inputStyle {
                for index in letters.indices where !letters[index].value.isFinite { letters[index].value = 0 }
                grade.inputStyle = .letters(letters)
            }
            self = .grade(grade)
        case .group(var group):
            for index in group.children.indices {
                let weight = group.children[index].weight
                if !(weight.isFinite && weight >= 0) { group.children[index].weight = 0 }
                group.children[index].node.sanitize()
            }
            self = .group(group)
        case .formula(var formula):
            for key in formula.variables.keys { formula.variables[key]?.sanitize() }
            self = .formula(formula)
        case .alternatives(var alternatives):
            for index in alternatives.branches.indices { alternatives.branches[index].node.sanitize() }
            self = .alternatives(alternatives)
        case .bonus, .requirement:
            break
        }
    }

    /// Sets the due date of the grade named `leaf`, wherever it sits in the tree.
    mutating func setDate(_ date: Date?, forLeaf leaf: String) {
        switch self {
        case .grade(var grade):
            guard grade.name == leaf else { return }
            grade.date = date
            self = .grade(grade)
        case .group(var group):
            for index in group.children.indices {
                group.children[index].node.setDate(date, forLeaf: leaf)
            }
            self = .group(group)
        case .formula(var formula):
            for key in formula.variables.keys {
                formula.variables[key]?.setDate(date, forLeaf: leaf)
            }
            self = .formula(formula)
        case .alternatives(var alternatives):
            for index in alternatives.branches.indices {
                alternatives.branches[index].node.setDate(date, forLeaf: leaf)
            }
            self = .alternatives(alternatives)
        case .bonus, .requirement:
            break
        }
    }

    var kindLabel: String {
        switch self {
        case .grade: "Nota única"
        case .group(let group):
            isGroupOfGrades
                ? "\(group.children.count) \(group.children.count == 1 ? "nota" : "notas")"
                : "\(group.children.count) \(group.children.count == 1 ? "parte" : "partes")"
        case .alternatives: "Alternativas"
        case .bonus: "Bonificación"
        case .requirement: "Requisito"
        case .formula: "Fórmula"
        }
    }

    /// What a row in the sections list says under the name: what it's made of and its minimum.
    var rowSubtitle: String {
        guard let minimum else { return kindLabel }
        return "\(kindLabel) · Mínimo \(minimum.threshold.formatted(.number.precision(.fractionLength(0...2))))"
    }

    /// The minimum on this node itself — a section's "Nota mínima" and what missing it does.
    var minimum: Minimum? {
        get { ownMinimum }
        set {
            switch self {
            case .group(var group): group.minimum = newValue; self = .group(group)
            case .formula(var formula): formula.minimum = newValue; self = .formula(formula)
            case .grade(var grade): grade.minimum = newValue; self = .grade(grade)
            case .alternatives(var alternatives): alternatives.minimum = newValue; self = .alternatives(alternatives)
            default: break
            }
        }
    }

    /// The pass threshold on this node's own result. Setting it keeps an existing consequence.
    var passThreshold: Double {
        get { minimumThreshold ?? 5 }
        set {
            switch self {
            case .group(var group):
                group.minimum = Minimum(threshold: newValue, consequence: group.minimum?.consequence ?? .fails)
                self = .group(group)
            case .formula(var formula):
                formula.minimum = Minimum(threshold: newValue, consequence: formula.minimum?.consequence ?? .fails)
                self = .formula(formula)
            case .grade(var grade):
                grade.minimum = Minimum(threshold: newValue, consequence: grade.minimum?.consequence ?? .fails)
                self = .grade(grade)
            case .alternatives(var alternatives):
                alternatives.minimum = Minimum(threshold: newValue, consequence: alternatives.minimum?.consequence ?? .fails)
                self = .alternatives(alternatives)
            default:
                break
            }
        }
    }
}

/// `Group.Combination` without its associated value, for a `Picker`.
enum CombinationKind: String, CaseIterable, Identifiable {
    case weightedAverage, sum, max, min, bestOf, undecided

    var id: Self { self }

    var label: String {
        switch self {
        case .weightedAverage: "Media ponderada"
        case .sum: "Suma"
        case .max: "La mejor"
        case .min: "La peor"
        case .bestOf: "Las mejores N"
        case .undecided: "Por definir"
        }
    }
}

extension Group.Combination {
    var kind: CombinationKind {
        switch self {
        case .weightedAverage: .weightedAverage
        case .sum: .sum
        case .max: .max
        case .min: .min
        case .bestOf: .bestOf
        case .undecided: .undecided
        }
    }

    init(kind: CombinationKind, bestOf count: Int) {
        switch kind {
        case .weightedAverage: self = .weightedAverage
        case .sum: self = .sum
        case .max: self = .max
        case .min: self = .min
        case .bestOf: self = .bestOf(count)
        case .undecided: self = .undecided
        }
    }

    var bestOfCount: Int? {
        if case .bestOf(let count) = self { count } else { nil }
    }
}

extension Formula {
    /// The same parts as an ordinary group, so it can be edited like any other subject. A formula
    /// has no fixed weights, so each part gets one from what it can contribute on its own (or,
    /// failing that, its maximum) — a starting point to correct, not the guide's exact rule.
    func asGroup(kind: CombinationKind) -> Engine.Group {
        let contributions = variables.keys.reduce(into: [String: Double]()) { $0[$1] = maxShare(of: $1) }
        let total = contributions.values.reduce(0, +)
        let ordered = expression.variableOrder.filter { variables[$0] != nil }
            + variables.keys.sorted().filter { !expression.variableOrder.contains($0) }
        let children = ordered.compactMap { key -> WeightedChild? in
            guard let node = variables[key] else { return nil }
            return WeightedChild(weight: total > 0 ? (contributions[key] ?? 0) / total : 1 / Double(variables.count), node: node)
        }
        return Engine.Group(
            name: name,
            combination: Engine.Group.Combination(kind: kind, bestOf: 1),
            children: children,
            minimum: minimum
        )
    }
}

extension Engine.Group {
    /// The same parts as a formula (`0,2 * A + 0,8 * B`), for subjects whose final grade doesn't come
    /// from fixed percentages. Only for weighted averages and sums, which a formula can say exactly.
    /// Each part gets a variable named after its first letter when that's free, else the next letter.
    func asFormula() -> Formula? {
        guard combination == .weightedAverage || combination == .sum, !children.isEmpty else { return nil }
        let total = children.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var variables: [String: Node] = [:]
        var terms: [Engine.Expression] = []
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        for child in children where child.node.scaleMax > 0 {
            let initial = child.node.title.first.map { String($0).uppercased() }
            let key = [initial].compactMap { $0 }.first { variables[$0] == nil && $0.first?.isLetter == true }
                ?? alphabet.first { variables[$0] == nil }
                ?? "V\(variables.count + 1)"
            variables[key] = child.node
            let share = combination == .sum ? child.weight : child.weight / total
            let coefficient = share * 10 / child.node.scaleMax
            terms.append(abs(coefficient - 1) < 1e-9
                ? .variable(key)
                : .multiply(.constant((coefficient * 1_000_000).rounded() / 1_000_000), .variable(key)))
        }
        guard var expression = terms.first else { return nil }
        for term in terms.dropFirst() { expression = .add(expression, term) }
        return Formula(name: name, expression: expression, variables: variables, minimum: minimum)
    }
}

extension SubjectRecord {
    /// Turns the evaluation into one copy per term (`labels`, "1º Trimestre"…), under a general
    /// evaluation that averages them (changed in the editor like any other). Grades already entered
    /// go to the first term. Leaf names have to stay unique, so each copy's carry its term; none is
    /// the final exam any more, since the sittings belong to the whole subject.
    mutating func splitByTerm(_ labels: [String]) {
        let base = subject.root
        let children = labels.enumerated().map { index, label in
            var node = base
            node.updateGrades { $0.isFinalExam = nil }
            node.renameLeaves { $0 + " (\(label))" }
            var term = Group(name: label, combination: .weightedAverage, children: [WeightedChild(weight: 1, node: node)])
            if case .group(let group) = node {
                term = group
                term.name = label
            }
            return WeightedChild(weight: 1 / Double(labels.count), node: .group(term))
        }
        subject.root = .group(Group(name: subject.name, combination: .weightedAverage, children: children))
        isPerTerm = true
    }
}
