import Engine
import SwiftUI

/// One sort option in a menu, ✓ when chosen. Name starts A to Z and grade highest first; choosing
/// the one already chosen flips it, and its subtitle says which way it runs. Home and the record
/// share it, each with its own stored order.
struct SubjectSortToggle: View {
    let option: SubjectSort
    @Binding var sort: SubjectSort
    @Binding var isAscending: Bool

    var body: some View {
        let isCurrent = sort == option
        Toggle(isOn: Binding(get: { isCurrent }, set: { _ in
            withAnimation(.snappy) {
                isAscending = isCurrent ? !isAscending : option != .grade
                sort = option
            }
        })) {
            // Loose texts and image, not a Label: in a menu a Label drops its second text.
            Text(option.title)
            if isCurrent && option != .custom {
                Text(isAscending ? "Ascendente" : "Descendente")
            }
            Image(systemName: option.icon)
        }
    }
}

/// How the subjects are laid out on the home screen: big cards in a grid, or one slim row each.
enum SubjectLayout: String, CaseIterable, Identifiable {
    case cards, list

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .cards: "Cuadrícula"
        case .list: "Lista"
        }
    }

    var icon: String {
        switch self {
        case .cards: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

/// The order the subjects are shown in: by name or by grade, either way round, or the one dragged by hand.
enum SubjectSort: String, CaseIterable, Identifiable {
    case name, grade, custom

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .name: "Nombre"
        case .grade: "Nota"
        case .custom: "Personalizado"
        }
    }

    var icon: String {
        switch self {
        case .name: "textformat"
        case .grade: "number"
        case .custom: "hand.draw"
        }
    }

    func sorted(_ records: [SubjectRecord], ascending: Bool) -> [SubjectRecord] {
        let byName: (SubjectRecord, SubjectRecord) -> Bool = {
            $0.subject.name.localizedStandardCompare($1.subject.name) == (ascending ? .orderedAscending : .orderedDescending)
        }
        switch self {
        case .custom:
            return records
        case .name:
            return records.sorted(by: byName)
        case .grade:
            // The grade guaranteed so far — the final one once everything's in.
            // "Por definir" has no grade at all: it sorts below every graded subject.
            let grades = Dictionary(records.map { record in
                let progress = SubjectProgress(record)
                return (record.id, progress.isUndecided ? -1 : progress.worst)
            }) { first, _ in first }
            return records.sorted {
                let (a, b) = (grades[$0.id] ?? 0, grades[$1.id] ?? 0)
                return a != b ? (ascending ? a < b : a > b) : byName($0, $1)
            }
        }
    }
}

/// The home screen: the year and term as a big title, then one large card per subject — just the
/// name. Everything else lives inside the subject.
struct HomeView: View {
    @Environment(Library.self) private var library
    /// Per-device conveniences: reopen on the period last looked at, in the layout last chosen.
    @AppStorage("selectedYear") private var selectedYear = 0
    @AppStorage("selectedTerm") private var selectedTerm = 0
    @AppStorage("subjectLayout") private var layout = SubjectLayout.cards
    @AppStorage("subjectSort") private var sort = SubjectSort.custom
    @AppStorage("subjectSortAscending") private var isAscending = true
    /// The custom view on screen, by id; empty when showing one of the degree's periods.
    @AppStorage("selectedCustomView") private var selectedCustomView = ""
    @State private var isChoosingView = false

    @State private var placement: SubjectPlacement?
    /// A subject to add once the study it needs has been created.
    @State private var pendingPlacement: SubjectPlacement?
    @State private var isCreatingStudy = false
    @State private var editing: SubjectRecord?
    @State private var customizing: SubjectRecord?
    @ScaledMetric(relativeTo: .largeTitle) private var yearSize = 32
    @ScaledMetric(relativeTo: .title) private var termSize = 24
    @State private var deleting: SubjectRecord?
    /// The "jiggle" mode: tiles wobble, can be dragged into a new order, and the gap after the
    /// last one offers a + to add a subject.
    @State private var isEditing = false
    @State private var viewportHeight: CGFloat = 0
    /// The "hold the background" tip: only shown after tapping the background itself.
    @State private var isShowingHint = false
    @State private var hintTask: Task<Void, Never>?

    /// Every period that has subjects, oldest first. A year-long subject belongs to every term of
    /// its year, so a year with one has all its terms, even if it's the only subject.
    private var periods: [Period] {
        let degree = library.degree
        var result: [Period] = []
        for course in library.courses {
            var terms = Set(course.subjects.compactMap(\.term))
            if course.subjects.contains(where: { $0.term == nil }) {
                terms.formUnion((1...max(degree.termsPerYear, 1)).map { degree.absoluteTerm(year: course.year, relative: $0) })
            }
            result += terms.sorted().map { Period(year: course.year, term: $0) }
        }
        return result.sorted { ($0.year, $0.term ?? 0) < ($1.year, $1.term ?? 0) }
    }

    /// Adding a subject with no current study (just archived one) sets the study up first.
    private func add(in period: Period) {
        if library.hasStudy {
            placement = .create(period)
        } else {
            pendingPlacement = .create(period)
            isCreatingStudy = true
        }
    }

    /// The new-study sheet has finished closing: on to the subject if a study was made.
    private func finishCreatingStudy() {
        if library.hasStudy { placement = pendingPlacement }
        pendingPlacement = nil
    }

    private func showHint() {
        isShowingHint = true
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { isShowingHint = false }
        }
    }

    private var period: Period {
        let stored = Period(year: selectedYear, term: selectedTerm == 0 ? nil : selectedTerm)
        return periods.contains(stored) ? stored : periods.first ?? Period(year: 1, term: 1)
    }

    /// The custom view on screen, if one is selected and still exists.
    private var customSelection: CustomSelection? {
        guard let id = UUID(uuidString: selectedCustomView) else { return nil }
        return library.selections.first { $0.id == id }
    }

    private var currentSelection: HomeSelection {
        customSelection.map { .custom($0.id) } ?? .period(period)
    }

    /// Where "Añadir asignatura" starts: the period on screen, or for a custom view the one its
    /// title names (picked by hand, or its furthest subject's).
    private var newSubjectPeriod: Period {
        guard let customSelection else { return period }
        if case .period(let year, let term) = customSelection.title { return Period(year: year, term: term) }
        return library.furthestPeriod(of: customSelection.subjectIDs) ?? period
    }

    private var customSubjects: [SubjectRecord] {
        customSelection?.subjectIDs.compactMap(library.record(id:)) ?? []
    }

    private var yearSubjects: [SubjectRecord] {
        library.courses.first { $0.year == period.year }?.subjects ?? []
    }

    /// The term's subjects, with the year-long ones graded per term among them.
    private var termSubjects: [SubjectRecord] {
        yearSubjects.filter { $0.term == period.term || (period.term != nil && $0.term == nil && $0.isPerTerm) }
    }

    /// Year-long subjects with one evaluation, listed under the term's own when one is selected.
    private var yearLongSubjects: [SubjectRecord] {
        period.term == nil ? [] : yearSubjects.filter { $0.term == nil && !$0.isPerTerm }
    }

    private var columns: [GridItem] {
        layout == .list ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 150), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if periods.isEmpty {
                    EmptyHome(hasStudy: library.hasStudy) { add(in: period) }
                        .frame(maxWidth: .infinity, minHeight: viewportHeight)
                } else {
                    VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        if let customSelection {
                            if customSubjects.isEmpty {
                                ContentUnavailableView {
                                    Label("Vista vacía", systemImage: "rectangle.dashed")
                                } description: {
                                    Text("Sus asignaturas se han borrado. Elige otras o cambia de vista.")
                                } actions: {
                                    Button("Editar vistas") { isChoosingView = true }
                                }
                            } else {
                                grid(customSubjects, in: customSelection)
                            }
                        } else {
                            grid(termSubjects, canAdd: true)
                        }
                        if customSelection == nil, !yearLongSubjects.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Anual")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.leading, 4)
                                grid(yearLongSubjects)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)

                    }
                    // Fills the screen so a tap on the empty space can end editing.
                    .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
                    .background {
                        if isEditing {
                            Color.clear
                                .contentShape(.rect)
                                .onTapGesture { isEditing = false }
                        } else {
                            LongPressBackground(onTap: showHint) { isEditing = true }
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .overlay(alignment: .bottom) {
                if isShowingHint && !isEditing {
                    Text("Mantén pulsado el fondo para reordenar o añadir asignaturas")
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .sensoryFeedback(.impact, trigger: isEditing)
            .animation(.snappy, value: isEditing)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: SubjectRecord.ID.self) { id in
                SubjectDetailView(recordID: id)
            }
            .navigationDestination(for: SubjectRoute.self) { route in
                SubjectDetailView(recordID: route.id, term: route.term)
            }
            .navigationDestination(isPresented: $isChoosingView) {
                HomeViewsScreen(periods: periods, current: currentSelection) { selection in
                    withAnimation(.snappy) {
                        switch selection {
                        case .period(let period): select(period)
                        case .custom(let id): selectedCustomView = id.uuidString
                        }
                    }
                }
            }
            .sheet(isPresented: $isCreatingStudy, onDismiss: finishCreatingStudy) {
                NewStudySheet()
            }
            .sheet(item: $placement) { placement in
                NewSubjectView(placement: placement, degree: library.degree) { saved, id in
                    // A subject created from a custom view joins it.
                    if case .create = placement, var selection = customSelection {
                        selection.subjectIDs.append(id)
                        library.saveSelection(selection)
                    }
                    show(saved)
                }
            }
            .sheet(item: $editing) { record in
                SubjectEditorView(record: record)
            }
            .sheet(item: $customizing) { record in
                CustomizeSubjectView(record: record)
            }
            .alert(
                "¿Eliminar \(deleting?.subject.name ?? "la asignatura")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
            ) {
                Button("Cancelar", role: .cancel) { deleting = nil }
                Button("Eliminar", role: .destructive) {
                    if let deleting { library.deleteSubject(id: deleting.id) }
                    deleting = nil
                }
            } message: {
                Text("Se borran también sus notas y fechas. No se puede deshacer.")
            }
        }
    }

    /// The year and term as the screen's title, big enough to read at a glance.
    private var header: some View {
        let heading: (title: String, subtitle: String?) = customSelection.map(library.heading(for:))
            ?? (period.title(in: library.degree), period.subtitle(in: library.degree))
        return VStack(alignment: .leading, spacing: 0) {
            Text(heading.title)
                .font(.system(size: yearSize, weight: .bold, design: .rounded))
            if let subtitle = heading.subtitle {
                Text(subtitle)
                    .font(.system(size: termSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .tourTarget("home.header")
    }

    /// A subject graded per term opens on the term on screen; anything else, and every subject in
    /// a custom view, opens whole.
    private func route(to record: SubjectRecord, in selection: CustomSelection?) -> SubjectRoute {
        let term = selection == nil && record.isPerTerm ? period.term.map(library.degree.relativeTerm) : nil
        return SubjectRoute(id: record.id, term: term)
    }

    /// `selection` set for a custom view: dragging reorders the view itself, not the subjects'
    /// years, and there's no + (subjects are added to a view from "Vista").
    /// Dragging always works: it keeps the order on screen as the new custom one and switches to it.
    private func grid(_ records: [SubjectRecord], canAdd: Bool = false, in selection: CustomSelection? = nil) -> some View {
        let records = sort.sorted(records, ascending: isAscending)
        let ids = records.map(\.id)
        return ReorderableGrid(
            records: records,
            isEditing: isEditing,
            columns: columns,
            isCompact: layout == .list,
            commit: { order in
                if let selection {
                    let rest = selection.subjectIDs.filter { !ids.contains($0) }
                    library.reorderSelection(selection.id, to: order + rest)
                } else {
                    library.reorderSubjects(order, before: nil, among: ids)
                }
                sort = .custom
            },
            onDelete: { deleting = $0 },
            normal: { record in
                NavigationLink(value: route(to: record, in: selection)) {
                    SubjectTile(record: record, isCompact: layout == .list, rounding: library.degree.rounding)
                }
                .buttonStyle(TilePressStyle())
                .tourTarget(record.id == records.first?.id && selection == nil ? "home.firstTile" : nil)
                .contextMenu {
                    Button("Personalizar", systemImage: "paintpalette") { customizing = record }
                    Button("Mover", systemImage: "arrow.right.circle") {
                        placement = .move(record.id, name: record.subject.name, from: library.period(of: record.id) ?? Period(year: period.year, term: record.term))
                    }
                    Button("Editar", systemImage: "slider.horizontal.3") { editing = record }
                    Divider()
                    Button("Eliminar", systemImage: "trash", role: .destructive) { deleting = record }
                }
            },
            trailing: {
                if canAdd {
                    AddTile(isCompact: layout == .list) { add(in: newSubjectPeriod) }
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Listo") { isEditing = false }
                    .fontWeight(.semibold)
            }
        } else if !periods.isEmpty {
            // With no subjects the screen is just the empty state and its button: nothing to sort,
            // lay out or switch between.
            if periods.count + library.selections.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        viewSwitcher
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Cambiar de vista")
                }
                // Keeps the two buttons as separate glass capsules instead of one joined pill.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Añadir asignatura", systemImage: "plus") { add(in: newSubjectPeriod) }
                    Button("Editar vistas", systemImage: "rectangle.stack") { isChoosingView = true }
                    Divider()
                    Picker("Diseño", selection: $layout) {
                        ForEach(SubjectLayout.allCases) { option in
                            Label(option.title, systemImage: option.icon).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    ForEach(SubjectSort.allCases) { option in
                        SubjectSortToggle(option: option, sort: $sort, isAscending: $isAscending)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Más opciones")
            }
        }
    }

    /// The calendar button's menu: a quick jump to any period or custom view, ✓ on the current one.
    /// Views are created and changed from "Editar vistas".
    @ViewBuilder
    private var viewSwitcher: some View {
        ForEach(Dictionary(grouping: periods, by: \.year).sorted { $0.key < $1.key }, id: \.key) { year, options in
            Section(library.degree.yearLabel(year)) {
                ForEach(options, id: \.self) { option in
                    switcherButton(option.term.map(library.degree.termLabel) ?? "Todo el año", isCurrent: currentSelection == .period(option)) {
                        select(option)
                    }
                }
            }
        }
        if !library.selections.isEmpty {
            Section("Personalizadas") {
                ForEach(library.selections) { selection in
                    let heading = library.heading(for: selection)
                    switcherButton([heading.title, heading.subtitle].compactMap { $0 }.joined(separator: " · "), isCurrent: currentSelection == .custom(selection.id)) {
                        selectedCustomView = selection.id.uuidString
                    }
                }
            }
        }
    }

    private func switcherButton(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy, action)
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func select(_ period: Period) {
        selectedCustomView = ""
        selectedYear = period.year
        selectedTerm = period.term ?? 0
    }

    /// After adding or moving a subject, follow it — a year-long one shows in the year's first term.
    /// Not while a custom view is on screen: the subject stays in it wherever it moved.
    private func show(_ saved: Period) {
        guard customSelection == nil else { return }
        select(saved.term == nil ? periods.first { $0.year == saved.year } ?? saved : saved)
    }
}

/// One subject: a decorative icon and its name, with a small ring in the corner that fills as
/// its grades are entered.
struct SubjectTile: View {
    let name: String
    let symbol: String
    let tint: Color
    /// Grades entered and grades in total, recomputed from the subject each time. `nil` hides the ring.
    let count: (entered: Int, total: Int)?
    /// The subject's grade once every grade is in; it takes the ring's place.
    let finalGrade: Double?
    /// "No presentado" in its current sitting: an NP takes the ring's place.
    var isNotPresented = false
    /// "Matrícula de honor", shown next to the final grade.
    var hasHonors = false
    /// A slim row (icon, name, ring) instead of the tall card, for the list view.
    var isCompact = false

    init(record: SubjectRecord, isCompact: Bool = false, rounding: GradeRounding = .none) {
        let style = SubjectStyle(record)
        let progress = SubjectProgress(record, rounding: rounding)
        self.init(
            name: record.subject.name, symbol: style.symbol, tint: style.tint,
            count: (progress.enteredCount, progress.leafCount),
            finalGrade: progress.isComplete ? progress.worst : nil
        )
        self.isNotPresented = progress.isNotPresented
        self.hasHonors = progress.hasHonors
        self.isCompact = isCompact
    }

    init(name: String, symbol: String, tint: Color, count: (entered: Int, total: Int)? = nil, finalGrade: Double? = nil) {
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.count = count
        self.finalGrade = finalGrade
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(tint.gradient, in: .rect(cornerRadius: 11))
    }

    @ViewBuilder
    private var indicator: some View {
        if isNotPresented {
            Text("NP")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .accessibilityLabel("No presentado")
        } else if let finalGrade {
            FinalGradeBadge(grade: finalGrade, hasHonors: hasHonors)
        } else if let count, count.total > 0 {
            CompletionRing(entered: count.entered, total: count.total)
        }
    }

    var body: some View {
        Group {
            if isCompact {
                HStack(spacing: 14) {
                    icon
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    indicator
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 68)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                .contentShape(.rect(cornerRadius: 18))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    icon
                    Spacer(minLength: 10)
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .frame(height: 156)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                .overlay(alignment: .topTrailing) {
                    indicator.padding(15)
                }
                .contentShape(.rect(cornerRadius: 22))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The final grade, in the colour of its band, once the ring would be full.
private struct FinalGradeBadge: View {
    let grade: Double
    var hasHonors = false

    var body: some View {
        let tint = GradeBand.color(for: grade)
        Text(hasHonors ? "\(grade.formatted(.number.precision(.fractionLength(0...2)))) MH" : grade.formatted(.number.precision(.fractionLength(0...2))))
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(tint == .yellow ? Color.orange : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .accessibilityLabel("Nota final \(grade.formatted(.number.precision(.fractionLength(0...2))))\(hasHonors ? ", matrícula de honor" : "")")
    }
}

/// A small circle that fills as grades are entered.
private struct CompletionRing: View {
    let entered: Int
    let total: Int

    private var fraction: Double { min(Double(entered) / Double(max(total, 1)), 1) }
    private var isComplete: Bool { entered >= total }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(isComplete ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
            }
        }
        .frame(width: 28, height: 28)
        .animation(.snappy, value: fraction)
        .accessibilityLabel("\(entered) de \(total) notas")
    }
}

/// The blue round + that fills the gap after the last subject while editing.
private struct AddTile: View {
    var isCompact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: isCompact ? 44 : 56, height: isCompact ? 44 : 56)
                .background(Color.accentColor, in: .circle)
                .frame(maxWidth: .infinity, minHeight: isCompact ? 68 : 156)
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel("Añadir asignatura")
    }
}

struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

private struct EmptyHome: View {
    let hasStudy: Bool
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Sin asignaturas", systemImage: "books.vertical")
        } description: {
            Text(hasStudy
                 ? "Añade las de este cuatrimestre o carga una plantilla en Cuenta → Plantillas."
                 : "No tienes ningún estudio en curso. Al añadir una asignatura creas uno nuevo.")
        } actions: {
            Button(action: add) {
                Label("Añadir asignatura", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderless)
                .tourTarget("home.add")
        }
    }
}

#Preview {
    HomeView()
        .environment(Library(fileURL: .temporaryDirectory.appending(path: "preview-library.json")))
}
