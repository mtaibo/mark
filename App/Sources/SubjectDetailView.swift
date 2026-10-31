import Engine
import PDFKit
import SwiftUI

/// One subject, as a few calm cards: where you stand (folded until you want the detail), the final
/// exam with its two sittings, and one card per other part showing its grade. Nothing here edits
/// the structure or the dates — that lives in the "…" menu; tapping a card opens just its grade.
/// A subject to open, and for one graded per term, the term of its year (1-based) it's opened from.
struct SubjectRoute: Hashable {
    let id: SubjectRecord.ID
    var term: Int?
}

struct SubjectDetailView: View {
    let recordID: SubjectRecord.ID
    /// Set for a subject graded per term opened from one of its terms: only that term's parts show.
    var term: Int?

    @Environment(Library.self) private var library
    @Environment(\.isSimulating) private var isSimulating
    @Environment(\.dismiss) private var dismiss
    @Environment(Tour.self) private var tour: Tour?
    @State private var isEditing = false
    @State private var isEditingDates = false
    @State private var addingDateFor: Convocatoria?
    @State private var gradeTarget: GradeTarget?
    @State private var simulation: Library?
    @State private var isImportingGuide = false
    @State private var isShowingGuide = false
    @State private var isConfirmingDeleteGuide = false
    @State private var guideError: String?

    var body: some View {
        if let record = library.record(id: recordID) {
            content(record)
        } else {
            ContentUnavailableView("Asignatura no encontrada", systemImage: "questionmark.folder")
        }
    }

    private func content(_ record: SubjectRecord) -> some View {
        let session = record.activeSession
        let scope = PartItem.termScope(of: record, session: session, term: term, termsPerYear: library.degree.termsPerYear)
        // Opened from a term, the card on top is that term's grade.
        let progress = SubjectProgress(record, session: session, rounding: library.degree.rounding, part: scope?.node)
        let items = scope?.items ?? PartItem.items(of: record, session: session)
        // "Nota única": one card for the final grade, no exam sittings.
        let exam = record.isSingleGrade ? nil : items.first(where: \.isExam)
        let others = items.filter { $0.id != exam?.id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isSimulating {
                    Label("Simulador", systemImage: "flask")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.14), in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("Simulador: no se guarda nada")
                }
                Text(record.subject.name)
                    .font(.largeTitle.bold())
                    .fixedSize(horizontal: false, vertical: true)

                if record.isUndecided {
                    UndecidedCard(progress: progress)
                        .tourTarget("subject.summary")
                } else {
                    GradeCard(
                        progress: progress,
                        session: session,
                        formula: (scope?.node ?? record.subject.root).asFormula,
                        needs: NeededGrade.rows(for: scope?.node ?? record.root(for: session), progress: progress, items: items)
                    )
                        .tourTarget("subject.summary")
                }

                // Only when a part is the final exam (never for "Nota única", which has none).
                if exam != nil {
                    ExamCard(
                        record: record,
                        exam: exam,
                        onAddDate: { addingDateFor = $0 },
                        onOpen: { session in open(GradeTarget(partID: exam?.id ?? "", session: session, isExam: true)) }
                    )
                    .tourTarget("subject.exam")
                }

                if !record.requirements.isEmpty {
                    RequirementsCard(record: record) { library.update($0) }
                }

                if !others.isEmpty {
                    // A single-grade subject's one card needs no heading.
                    if !record.isSingleGrade {
                        Text("Notas")
                            .font(.title3.bold())
                            .padding(.top, 8)
                            .padding(.horizontal, 4)
                    }

                    VStack(spacing: 12) {
                        ForEach(others) { item in
                            PartCard(item: item, record: record, session: session, progress: progress)
                                .onTapGesture {
                                    open(GradeTarget(partID: item.id, session: session))
                                }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .tourTarget("subject.parts")
                }

                if let earlier = scope?.earlier, !earlier.isEmpty {
                    EarlierTermsCard(terms: earlier, record: record, session: session, title: "\(library.degree.pluralTermName) anteriores")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        // Just enough blur to set the card apart, animated together with it; the content only, so
        // the background stays solid out to the screen's edges.
        .blur(radius: gradeTarget == nil ? 0 : 2.5)
        .background(Color(.systemGroupedBackground))
        .overlay {
            GradePopup(recordID: recordID, term: term, target: gradeTarget) { close() }
        }

        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSimulating)
        .onAppear { if !isSimulating { tour?.perform(.subjectOpened) } }
        .toolbar {
            if isSimulating {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Salir del simulador", systemImage: "xmark") { dismiss() }
                }
            } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Editar", systemImage: "slider.horizontal.3") { isEditing = true }
                    if !(library.record(id: recordID)?.isSingleGrade ?? false) {
                        Button("Fechas", systemImage: "calendar") { isEditingDates = true }
                    }
                    // "Por definir" has no grade to simulate.
                    if !record.isUndecided {
                        Button("Simulador", systemImage: "flask") {
                            simulation = Library(simulating: record, degree: library.degree)
                        }
                    }
                    Divider()
                    if let alternatives = record.subject.root.asAlternatives, !alternatives.pickBest {
                        Picker(selection: Binding(
                            get: { alternatives.selected ?? 0 },
                            set: { index in
                                var changed = record
                                changed.subject.root.asAlternatives?.selected = index
                                library.update(changed)
                            }
                        )) {
                            ForEach(alternatives.branches.indices, id: \.self) { index in
                                Text(alternatives.branches[index].node.title).tag(index)
                            }
                        } label: {
                            Label("Modalidad", systemImage: "arrow.triangle.branch")
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle(isOn: Binding(
                        get: { record.isNotPresented(in: session) },
                        set: { value in
                            var changed = record
                            if session == .ordinary { changed.ordinaryNotPresented = value } else { changed.extraordinaryNotPresented = value }
                            library.update(changed)
                        }
                    )) {
                        Label("No presentado en la \(session.label.lowercased())", systemImage: "person.slash")
                    }
                    if record.hasHonors || (progress.isComplete && progress.worst >= 9) {
                        Toggle(isOn: Binding(
                            get: { record.hasHonors },
                            set: { value in
                                var changed = record
                                changed.hasHonors = value
                                library.update(changed)
                            }
                        )) {
                            Label("Matrícula de honor", systemImage: "rosette")
                        }
                    }
                    Divider()
                    if library.guideIDs.contains(recordID) {
                        Button("Abrir guía", systemImage: "doc.text") { isShowingGuide = true }
                        Button("Borrar guía", systemImage: "trash", role: .destructive) { isConfirmingDeleteGuide = true }
                    } else {
                        Button("Subir guía", systemImage: "square.and.arrow.up") { isImportingGuide = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Más opciones")
            }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { simulation != nil }, set: { if !$0 { simulation = nil } })) {
            if let simulation {
                NavigationStack {
                    SubjectDetailView(recordID: recordID, term: term)
                }
                .environment(simulation)
                .environment(\.isSimulating, true)
            }
        }
        .sheet(isPresented: $isEditing) {
            SubjectEditorView(record: record)
        }
        .sheet(isPresented: $isEditingDates) {
            DatesSheet(recordID: recordID)
        }
        .sheet(item: $addingDateFor) { session in
            ExamDateSheet(session: session) { library.setExamDate($0, for: session, in: recordID) }
        }
        .sheet(isPresented: $isShowingGuide) {
            if let url = library.guideURL(for: recordID) {
                GuideSheet(url: url, title: record.subject.name)
            }
        }
        .fileImporter(isPresented: $isImportingGuide, allowedContentTypes: [.pdf]) { result in
            importGuide(result)
        }
        .confirmationDialog("¿Borrar la guía?", isPresented: $isConfirmingDeleteGuide, titleVisibility: .visible) {
            Button("Borrar guía", role: .destructive) { library.removeGuide(for: recordID) }
        } message: {
            Text("Se borra el PDF guardado en el móvil. Podrás subirlo otra vez.")
        }
        .alert("No se ha podido subir la guía", isPresented: Binding(get: { guideError != nil }, set: { if !$0 { guideError = nil } })) {
            Button("Vale") {}
        } message: {
            Text(guideError ?? "")
        }
    }
}

extension SubjectDetailView {
    /// One animation in and one out: the card slides from the top while the screen behind blurs
    /// slightly and dims.
    fileprivate func open(_ target: GradeTarget) {
        withAnimation(.snappy(duration: 0.36)) { gradeTarget = target }
    }

    fileprivate func close() {
        withAnimation(.snappy(duration: 0.3)) { gradeTarget = nil }
    }

    /// Reads the chosen PDF (it must really be one) and keeps a copy inside the app — read and
    /// checked off the main thread, so a big guide doesn't freeze the screen.
    fileprivate func importGuide(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), PDFDocument(data: data) != nil else { return nil }
                return data
            }.value
            guard let data else {
                guideError = "El archivo no es un PDF válido."
                return
            }
            do {
                try library.setGuide(data, for: recordID)
            } catch {
                guideError = error.localizedDescription
            }
        }
    }
}

/// The stored guide, scrollable and zoomable. It's opened off the main thread (a long guide took
/// a while and froze the sheet) and only shown once it's read.
private struct GuideSheet: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var document: LoadedPDF?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    PDFKitView(document: document.document)
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    ContentUnavailableView("No se puede abrir la guía", systemImage: "doc.questionmark", description: Text("Bórrala desde «…» y súbela otra vez."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(item: url)
                }
            }
        }
        .task {
            let url = url
            let loaded = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url).map(LoadedPDF.init)
            }.value
            document = loaded
            failed = loaded == nil
        }
    }
}

/// A read PDF handed from the loading task to the view; PDFKit's document isn't `Sendable`, but
/// it's only touched again on the main thread once handed over.
private final class LoadedPDF: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) { self.document = document }
}

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> GuidePDFView {
        let view = GuidePDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        return view
    }

    func updateUIView(_ view: GuidePDFView, context: Context) {}
}

/// Scales the pages to the width only once the view has a size: with `autoScales` on from the
/// start, PDFKit worked out a scale from a zero-sized view and the app could crash opening a guide.
private final class GuidePDFView: PDFView {
    private var didScale = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didScale, bounds.width > 0, bounds.height > 0, document != nil else { return }
        didScale = true
        autoScales = true
        // PDFView scrolls with a UIKit scroll view inside, which SwiftUI's scrollIndicators doesn't reach.
        for case let scrollView as UIScrollView in subviews {
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = false
        }
    }
}

private extension EnvironmentValues {
    /// True inside the simulator, where nothing is saved and editing the subject itself is off.
    @Entry var isSimulating = false
}

/// Which part's grades to fill in, and for which sitting.
private struct GradeTarget: Identifiable {
    let partID: String
    let session: Convocatoria
    /// Opened from the exam card.
    var isExam = false
    let id = UUID()
}

// MARK: - Grade

/// In place of the grade for a "Por definir" subject: just how many notes are in. The evaluation
/// is picked from "Editar" once it's known.
private struct UndecidedCard: View {
    let progress: SubjectProgress

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Evaluación por definir", systemImage: "questionmark.circle")
                .font(.headline)
            Spacer(minLength: 8)
            Text(progress.leafCount == 0 ? "Sin notas" : "\(progress.enteredCount) de \(progress.leafCount)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

/// Conditions with no grade (attendance…), each marked met, not met or still unknown; one not
/// met fails the subject.
private struct RequirementsCard: View {
    let record: SubjectRecord
    let onChange: (SubjectRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requisitos")
                .font(.headline)
            ForEach(record.requirements) { requirement in
                HStack {
                    Text(requirement.name)
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    Picker(requirement.name, selection: Binding(
                        get: { requirement.isMet },
                        set: { value in
                            var changed = record
                            if let index = changed.requirements.firstIndex(where: { $0.id == requirement.id }) {
                                changed.requirements[index].isMet = value
                            }
                            onChange(changed)
                        }
                    )) {
                        Text("Pendiente").tag(Bool?.none)
                        Text("Cumplido").tag(Bool?.some(true))
                        Text("No cumplido").tag(Bool?.some(false))
                    }
                    .labelsHidden()
                    .tint(requirement.isMet == false ? .red : requirement.isMet == true ? .green : .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The grade up front with its bar; tap to unfold what's secured, what's still reachable, the pass
/// mark and what's needed.
private struct GradeCard: View {
    let progress: SubjectProgress
    let session: Convocatoria
    let formula: Formula?
    let needs: [NeededGrade]

    @State private var isExpanded = false

    private var hasGrades: Bool { progress.enteredCount > 0 }

    /// Blue while grades are missing; once everything is in, the colour of the final grade.
    private var barTint: Color {
        progress.isComplete ? GradeBand.color(for: progress.worst) : .accentColor
    }

    /// For the verdict sentence: a sure pass or a lost one get a colour of their own.
    private var tint: Color {
        if progress.isNotPresented { return .secondary }
        if progress.missesARequirement { return .red }
        guard hasGrades else { return .secondary }
        switch progress.status {
        case .guaranteed: return .green
        case .possible: return .accentColor
        case .impossible: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Oculta el detalle" : "Muestra el detalle")

            GradeRangeBar(worst: progress.worst, best: hasGrades ? progress.best : 0, threshold: progress.threshold, tint: barTint)

            if isExpanded {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 36) {
                        GradeStat(label: "Asegurada", value: progress.worst, swatch: AnyShapeStyle(barTint))
                        GradeStat(label: "Máxima", value: hasGrades ? progress.best : 10, swatch: AnyShapeStyle(barTint.opacity(0.25)))
                        // Almost always a 5; only worth a column when the guide asks for something else.
                        if progress.threshold != 5 {
                            GradeStat(label: "Apruebas con", value: progress.threshold, swatch: AnyShapeStyle(.primary.opacity(0.6)), isTick: true)
                        }
                    }
                    if !needs.isEmpty {
                        NeedsList(needs: needs)
                    } else if let message = verdict {
                        Label {
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: verdictIcon)
                        }
                        .font(.subheadline)
                        .foregroundStyle(tint)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tint.opacity(0.1), in: .rect(cornerRadius: 12))
                    }
                    if let formula {
                        Text(formula.expression.source)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                // Only fade: sliding in from the top made it pass over the bar while the card grew.
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.08)),
                    removal: .opacity.animation(.easeIn(duration: 0.12))
                ))
            }
        }
        .card(padding: 18)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if progress.isNotPresented {
                        Text("NP")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("No presentado")
                    } else {
                        Text(progress.worst, format: .number.precision(.fractionLength(0...2)))
                            .foregroundStyle(hasGrades ? .primary : .tertiary)
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("/ 10")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        if progress.hasHonors {
                            Text("MH")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(GradeBand.color(for: 10))
                                .padding(.leading, 6)
                                .accessibilityLabel("Matrícula de honor")
                        }
                    }
                }
                if session == .extraordinary {
                    Text(session.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            ProgressPill(progress: progress, hasGrades: hasGrades)
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .contentShape(.rect)
    }

    /// The one sentence that answers "and so what?" for the numbers.
    private var verdict: LocalizedStringKey? {
        if progress.isNotPresented {
            return "No presentado en la \(session.label.lowercased()): no cuenta como suspenso ni entra en la media."
        }
        if progress.missesARequirement {
            return "No cumples un requisito de la asignatura, así que no apruebas aunque las notas lleguen."
        }
        guard hasGrades else { return nil }
        switch progress.status {
        case .guaranteed:
            return "Ya tienes el aprobado, pase lo que pase en lo que falta."
        case .impossible:
            return "Aunque saques un 10 en todo lo que falta, no llegas al \(progress.threshold.formatted())."
        case .possible:
            guard let needed = progress.neededAverage else { return nil }
            return "Para aprobar necesitas un **\(needed.formatted(.number.precision(.fractionLength(1))))** de media en lo que falta."
        }
    }

    private var verdictIcon: String {
        if progress.isNotPresented { return "person.slash" }
        switch progress.status {
        case .guaranteed: return "checkmark.seal.fill"
        case .impossible: return "exclamationmark.triangle.fill"
        case .possible: return "target"
        }
    }
}

/// The least each pending part needs for the subject to pass, the final exam last: the other parts
/// aim at their own pass mark and the exam makes up the rest (see `Node.passPlan`).
private struct NeededGrade: Identifiable {
    let id: String
    let title: String
    /// True when several grades of the part are still to come: the value is what they need on average.
    let isAverage: Bool
    let value: Double
    let scaleMax: Double

    /// `root`: the evaluation the card on top is about — the subject's, or the term's on screen.
    static func rows(for root: Node, progress: SubjectProgress, items: [PartItem]) -> [NeededGrade] {
        guard progress.status == .possible,
              let plan = root.passPlan(progress.inputs, target: progress.target)
        else { return [] }
        let ordered = items.filter { !$0.isExam } + items.filter(\.isExam)
        return ordered.compactMap { item in
            let leaves = item.node.allLeafNames()
            let pending = leaves.filter { plan[$0] != nil }
            guard let first = pending.first, let leaf = item.node.leaf(named: first) else { return nil }
            let value = pending.compactMap { plan[$0] }.max() ?? 0
            let scaleMax = leaf.scaleMax
            if item.node.asGrade != nil || leaves.count == 1 {
                return NeededGrade(id: item.id, title: item.node.title, isAverage: false, value: value * scaleMax, scaleMax: scaleMax)
            } else if pending.count == 1 {
                return NeededGrade(id: item.id, title: first, isAverage: false, value: value * scaleMax, scaleMax: scaleMax)
            } else {
                return NeededGrade(id: item.id, title: item.node.title, isAverage: true, value: value * scaleMax, scaleMax: scaleMax)
            }
        }
    }
}

/// "Para aprobar": one row per pending part with the grade it needs.
private struct NeedsList: View {
    let needs: [NeededGrade]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Only the title is blue, on a faint band behind its one line.
            Label("Para aprobar", systemImage: "target")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 7)
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
            ForEach(needs) { need in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(need.title)
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    valueText(need)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func valueText(_ need: NeededGrade) -> some View {
        // Rounded up: a 4,66 shown as 4,7 still passes, as 4,6 it wouldn't.
        let value = (need.value * 10 - 0.0001).rounded(.up) / 10
        if value <= 0 {
            Text("Cualquier nota")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            let number = value.formatted(.number.precision(.fractionLength(0...1)))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if need.isAverage {
                    Text("media")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(need.scaleMax == 10 ? number : "\(number) / \(need.scaleMax.formatted())")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }
        }
    }
}

/// One number of the unfolded grade card, with the swatch that finds it on the bar above.
private struct GradeStat: View {
    let label: LocalizedStringKey
    let value: Double
    let swatch: AnyShapeStyle
    var isTick = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if isTick {
                    Rectangle().fill(swatch).frame(width: 2, height: 10)
                } else {
                    Capsule().fill(swatch).frame(width: 12, height: 6)
                }
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(0...2)))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

/// How far along you are ("3 de 5 notas"), not how worried to be; a sure pass or a lost one say so.
private struct ProgressPill: View {
    let progress: SubjectProgress
    let hasGrades: Bool

    var body: some View {
        let (text, icon, tint): (String, String?, Color) = if progress.isNotPresented {
            ("No presentado", nil, .secondary)
        } else if progress.missesARequirement {
            ("No llega", "xmark.circle.fill", .red)
        } else if !hasGrades {
            ("Sin notas", nil, .secondary)
        } else {
            switch progress.status {
            case .guaranteed: ("Aprobada", "checkmark.circle.fill", .green)
            case .impossible: ("No llega", "xmark.circle.fill", .red)
            case .possible: ("\(progress.enteredCount) de \(progress.leafCount)", nil, .secondary)
            }
        }
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text).monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Exam

/// The final exam, which every subject has: its weight and, below it, one row per sitting with the
/// grade, its own bar and the date, laid out like the other part cards. Tap a slot to put its grade; the date is changed from "…".
private struct ExamCard: View {
    let record: SubjectRecord
    let exam: PartItem?
    let onAddDate: (Convocatoria) -> Void
    let onOpen: (Convocatoria) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exam?.node.title ?? "Examen")
                    .font(.headline)
                if let weightPercent = exam?.weightPercent {
                    WeightChip(percent: weightPercent, isMaximum: exam?.isMaximum == true)
                }
            }
            .padding(.bottom, 6)
            ForEach(Convocatoria.allCases) { session in
                if session != Convocatoria.allCases.first {
                    Divider()
                }
                ExamSlot(
                    session: session,
                    date: record.examDate(for: session),
                    summary: exam.map { PartSummary(node: $0.node, record: record, session: session) },
                    onAddDate: { onAddDate(session) },
                    onOpen: { onOpen(session) }
                )
            }
        }
        .card()
    }
}

private struct ExamSlot: View {
    let session: Convocatoria
    let date: Date?
    let summary: PartSummary?
    let onAddDate: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.label)
                        .font(.subheadline.weight(.semibold))
                    dateLine
                }
                Spacer(minLength: 8)
                if let summary {
                    Text(summary.text)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(summary.hasAnyGrade ? .primary : .tertiary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if let summary {
                ProgressBar(fraction: summary.fraction, tint: summary.tint)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if summary != nil { onOpen() } }
    }

    @ViewBuilder
    private var dateLine: some View {
        if let date {
            Text("\(date.formatted(.dateTime.day().month(.abbreviated))) · \(Self.remaining(until: date))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            // Plain and fixed to its own label: as a borderless button its tap area reached up over
            // the sitting's name, so tapping «Ordinaria» opened the date instead of the grade.
            Button(action: onAddDate) {
                Label("Añadir fecha", systemImage: "plus")
                    .padding(.vertical, 4)
                    .contentShape(.rect)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.tint)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private static func remaining(until date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "Hoy"
        case 1: return "Mañana"
        case 2...: return "Quedan \(days) días"
        case -1: return "Fue ayer"
        default: return "Hace \(-days) días"
        }
    }
}

/// Picks a first exam date. Once set it only changes from "Fechas".
private struct ExamDateSheet: View {
    let session: Convocatoria
    let onSave: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Fecha", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("Examen · \(session.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        onSave(date)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}

/// Every date of the subject in one place: both exams and the due date of each grade.
private struct DatesSheet: View {
    let recordID: SubjectRecord.ID

    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let record = library.record(id: recordID) {
                Form {
                    let exam = record.subject.root.examTitle
                    Section(exam ?? "Examen") {
                        ForEach(Convocatoria.allCases) { session in
                            DateToggleRow(title: session.label, defaultHour: 9, date: Binding(
                                get: { record.examDate(for: session) },
                                set: { library.setExamDate($0, for: session, in: recordID) }
                            ))
                        }
                    }
                    let leaves = record.subject.root.allLeafNames().filter { 
                        guard let grade = record.subject.root.leaf(named: $0)?.asGrade else { return false }
                        return grade.isFinalExam != true
                    }
                    if !leaves.isEmpty {
                        Section("Pruebas y entregas") {
                            ForEach(leaves, id: \.self) { name in
                                DateToggleRow(title: name, defaultHour: 23, date: Binding(
                                    get: { record.subject.root.leaf(named: name)?.asGrade?.date },
                                    set: { library.setGradeDate($0, forLeaf: name, in: recordID) }
                                ))
                            }
                        }
                    }
                }
                .navigationTitle("Fechas")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
            }
        }
    }
}

private struct DateToggleRow: View {
    let title: String
    let defaultHour: Int
    @Binding var date: Date?

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(title, isOn: Binding(
                get: { date != nil },
                set: { date = $0 ? Calendar.current.date(bySettingHour: defaultHour, minute: defaultHour == 23 ? 59 : 0, second: 0, of: .now) : nil }
            ))
            if let date = Binding(unwrapping: $date) {
                DatePicker("Fecha", selection: date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
        }
    }
}

// MARK: - Parts

/// One top-level part of the evaluation, with the share of the grade it carries.
private struct PartItem: Identifiable {
    let id: String
    let node: Node
    let weightPercent: Double?
    /// True when the share is a ceiling ("hasta 80 %") because the formula decides the real one.
    var isMaximum = false

    var isExam: Bool { node.isFinalExamPart }

    /// The cards for a sitting: the parts of its tree (the extraordinary's own, if it has one). With
    /// continuous and single-exam schemes, the chosen one's parts, or both's when the best counts
    /// — a note they share shows once.
    static func items(of record: SubjectRecord, session: Convocatoria) -> [PartItem] {
        let root = session == .extraordinary ? (record.extraordinaryRoot ?? record.subject.root) : record.subject.root
        guard case .alternatives(let alternatives) = root else { return items(of: root) }
        var seen: Set<String> = []
        return Node.activeBranches(alternatives).flatMap { items(of: $0.node) }.filter { item in
            let leaves = item.node.allLeafNames()
            defer { seen.formUnion(leaves) }
            return leaves.isEmpty || !leaves.allSatisfy(seen.contains)
        }
    }

    /// A subject graded per term, opened from one of its terms: that term's parts, plus the terms
    /// before it when it's the year's last. Nil — show the whole subject — when no term is given or
    /// the general evaluation no longer has one part per term.
    static func termScope(of record: SubjectRecord, session: Convocatoria, term: Int?, termsPerYear: Int) -> (node: Node, items: [PartItem], earlier: [PartItem])? {
        guard record.isPerTerm, let term else { return nil }
        let terms = items(of: record, session: session)
        guard terms.count == termsPerYear, terms.indices.contains(term - 1) else { return nil }
        let node = terms[term - 1].node
        return (node, items(of: node), term == terms.count ? Array(terms.prefix(term - 1)) : [])
    }

    static func items(of root: Node) -> [PartItem] {
        if case .group(let group) = root, group.combination == .undecided {
            return group.children.map { PartItem(id: $0.id.uuidString, node: $0.node, weightPercent: nil) }
        } else if case .group(let group) = root {
            let total = group.combination == .weightedAverage ? group.children.reduce(0) { $0 + $1.weight } : 1
            return group.children.map { child in
                PartItem(id: child.id.uuidString, node: child.node, weightPercent: total > 0 ? child.weight / total * 100 : nil)
            }
        } else if case .formula(let formula) = root {
            let keys = formula.expression.variableOrder.filter { formula.variables[$0] != nil }
                + formula.variables.keys.sorted().filter { !formula.expression.variableOrder.contains($0) }
            return keys.compactMap { key in
                formula.variables[key].map {
                    PartItem(id: key, node: $0, weightPercent: formula.maxShare(of: key) * 10, isMaximum: true)
                }
            }
        } else {
            return [PartItem(id: "root", node: root, weightPercent: nil)]
        }
    }
}

/// How a part stands in one sitting: what to show, how full its bar is and what colour. The bar is
/// blue until every grade in the part is in, then red / yellow / green / purple by the part's grade.
private struct PartSummary {
    let text: String
    let fraction: Double
    let tint: Color
    let hasAnyGrade: Bool

    init(node: Node, record: SubjectRecord, session: Convocatoria) {
        let inputs = SubjectProgress.inputs(record, session: session)
        let leaves = node.allLeafNames()
        let entered = leaves.count { inputs[$0] != nil }
        hasAnyGrade = entered > 0
        let complete = !leaves.isEmpty && entered == leaves.count
        if record.isUndecided, node.asGrade == nil {
            // Nothing is combined: the bar and the text say how many notes are in, not a grade.
            fraction = leaves.isEmpty ? 0 : Double(entered) / Double(leaves.count)
            tint = .accentColor
            text = leaves.isEmpty ? "—" : "\(entered) de \(leaves.count)"
            return
        }
        let max = node.scaleMax
        let value = node.evaluate(inputs, pendingFraction: 0)
        fraction = max > 0 ? Swift.min(Swift.max(value / max, 0), 1) : 0
        tint = complete ? GradeBand.color(for: fraction * 10) : .accentColor
        if let grade = node.asGrade {
            text = Self.display(of: grade, record: record, session: session)
        } else if complete {
            text = (fraction * 10).formatted(.number.precision(.fractionLength(0...2)))
        } else if leaves.count > 1 {
            text = "\(entered) de \(leaves.count)"
        } else {
            text = "—"
        }
    }

    static func display(of grade: Grade, record: SubjectRecord, session: Convocatoria) -> String {
        record.displayedEntry(for: grade, in: session)
    }
}

/// A due date in small type, like "27/06/26", struck through once it has passed.
private struct DueDateLabel: View {
    let date: Date

    var body: some View {
        Text(date, format: .dateTime.day(.twoDigits).month(.twoDigits).year(.twoDigits))
            .font(.footnote.monospacedDigit())
            .strikethrough(date < .now)
            .foregroundStyle(.secondary)
    }
}

private struct WeightChip: View {
    let percent: Double
    var isMaximum = false

    var body: some View {
        Text("\(isMaximum ? "hasta " : "")\(percent.formatted(.number.precision(.fractionLength(0...1)))) %")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

/// A part at a glance: name, weight, what's in so far and a thin bar. Read-only.
private struct PartCard: View {
    let item: PartItem
    let record: SubjectRecord
    let session: Convocatoria
    let progress: SubjectProgress

    var body: some View {
        let summary = PartSummary(node: item.node, record: record, session: session)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.node.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                if let weightPercent = item.weightPercent {
                    WeightChip(percent: weightPercent, isMaximum: item.isMaximum)
                }
                Spacer(minLength: 8)
                if let date = item.node.asGrade?.date {
                    DueDateLabel(date: date)
                }
                Text(summary.text)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(summary.hasAnyGrade ? .primary : .tertiary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            ProgressBar(fraction: summary.fraction, tint: summary.tint)
            if let group = item.node.asGroup, group.children.allSatisfy({ $0.node.asGrade != nil }) {
                // A grid, so the dates and the values line up in columns whatever their width
                // ("8,3" above "0,83 / 2").
                let hasDates = group.children.contains { $0.node.asGrade?.date != nil }
                let shares = absoluteShares(of: group)
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(group.children) { child in
                        if let grade = child.node.asGrade {
                            GridRow {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(grade.name)
                                        .foregroundStyle(.secondary)
                                    if let share = shares[child.id] {
                                        Text("\(share.formatted(.number.precision(.fractionLength(0...2))))\u{00A0}%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                    .gridColumnAlignment(.leading)
                                if hasDates {
                                    if let date = grade.date {
                                        DueDateLabel(date: date)
                                    } else {
                                        Color.clear.frame(width: 0, height: 0)
                                    }
                                }
                                Text(PartSummary.display(of: grade, record: record, session: session))
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
        }
        .card()
        .contentShape(.rect)
        // One element for VoiceOver: "Prácticas, 40 %, 7,5. Abre para poner sus notas."
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(summary))
        .accessibilityHint("Abre sus notas")
    }

    private func accessibilityText(_ summary: PartSummary) -> String {
        var parts = [item.node.title]
        if let weight = item.weightPercent {
            parts.append("\(item.isMaximum ? "hasta " : "")\(weight.formatted(.number.precision(.fractionLength(0...1)))) por ciento")
        }
        parts.append(summary.hasAnyGrade ? summary.text : "sin notas")
        if let group = item.node.asGroup, group.children.allSatisfy({ $0.node.asGrade != nil }) {
            for child in group.children {
                if let grade = child.node.asGrade {
                    parts.append("\(grade.name): \(PartSummary.display(of: grade, record: record, session: session))")
                }
            }
        }
        return parts.joined(separator: ", ").replacingOccurrences(of: "—", with: "sin nota")
    }

    /// Each note's share of the whole subject — its share of the part times the part's weight, so
    /// a practical worth a third of a 10 % part reads 3,33 %. Only when the subject is a weighted
    /// average and the part splits by fixed weights (an average or a sum); empty otherwise.
    private func absoluteShares(of group: Engine.Group) -> [WeightedChild.ID: Double] {
        guard record.subject.root.asGroup?.combination == .weightedAverage, let partPercent = item.weightPercent,
              group.combination == .weightedAverage || group.combination == .sum else { return [:] }
        let total = group.children.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: group.children.map { ($0.id, $0.weight / total * partPercent) })
    }
}

/// In the last term of a subject graded per term: how the earlier ones went, a row each, and the
/// whole year's grade below them.
private struct EarlierTermsCard: View {
    let terms: [PartItem]
    let record: SubjectRecord
    let session: Convocatoria
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            ForEach(terms) { term in
                let summary = PartSummary(node: term.node, record: record, session: session)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(term.node.title)
                            .font(.subheadline.weight(.medium))
                        if let weightPercent = term.weightPercent {
                            WeightChip(percent: weightPercent, isMaximum: term.isMaximum)
                        }
                        Spacer(minLength: 8)
                        Text(summary.text)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(summary.hasAnyGrade ? .primary : .tertiary)
                    }
                    ProgressBar(fraction: summary.fraction, tint: summary.tint)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(term.node.title), \(summary.hasAnyGrade ? summary.text : "sin notas")")
            }
            Divider()
            let year = PartSummary(node: record.root(for: session), record: record, session: session)
            HStack(alignment: .firstTextBaseline) {
                Text("Nota del curso")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(year.text)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(year.hasAnyGrade ? .primary : .tertiary)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
        .animation(.snappy, value: fraction)
    }
}

/// Where a grade is typed: a card pinned to the top of the screen over a blurred background, so the
/// keyboard rising from the bottom never pushes it around. It focuses the first empty field, and
/// "Hecho" or a tap outside closes it.
/// One part's grades for one sitting, in a card that slides down from the top over a softly
/// blurred screen, the first empty note ready to type in. Each grade is saved as it's typed; «Hecho» or a
/// tap on the dim closes it.
///
/// Its height comes from how many notes the part has, never measured while it animates, and the
/// keyboard rises along with it, so opening and closing stay one smooth motion.
private struct GradePopup: View {
    let recordID: SubjectRecord.ID
    let term: Int?
    let target: GradeTarget?
    let onClose: () -> Void

    @Environment(Library.self) private var library
    @FocusState private var focusedField: String?

    /// The part tapped, in the sitting asked for; the exam's slot finds the exam even when the
    /// extraordinary has a tree of its own.
    static func item(in record: SubjectRecord, term: Int?, termsPerYear: Int, for target: GradeTarget) -> PartItem? {
        let items = PartItem.termScope(of: record, session: target.session, term: term, termsPerYear: termsPerYear)?.items
            ?? PartItem.items(of: record, session: target.session)
        return items.first { $0.id == target.partID } ?? (target.isExam ? items.first(where: \.isExam) : nil)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let target, let record = library.record(id: recordID), let item = Self.item(in: record, term: term, termsPerYear: library.degree.termsPerYear, for: target) {
                // A light dim; the screen itself is softly blurred behind it (see `content`).
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .transition(.opacity)
                card(record: record, item: item, session: target.session)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: target.id) {
                        // Together with the slide: the card has a fixed height and ignores the
                        // keyboard, so both can move at once. A beat first, so the field is on
                        // screen before it's focused.
                        try? await Task.sleep(for: .milliseconds(50))
                        let leaves = item.node.allLeafNames()
                        if let first = leaves.first(where: { record.entry(for: $0, in: target.session) == nil }) ?? leaves.first {
                            focusedField = "\(target.session.rawValue)/\(first)"
                        }
                    }
            }
        }
        // The card stays put at the top whatever the keyboard does.
        .ignoresSafeArea(.keyboard)
    }

    private func close() {
        focusedField = nil
        onClose()
    }

    private func card(record: SubjectRecord, item: PartItem, session: Convocatoria) -> some View {
        let content = PartContent(node: item.node, context: PartContext(
            record: record, session: session, inputs: SubjectProgress.inputs(record, session: session), focus: $focusedField
        ) { leaf, entry in
            library.setEntry(entry, forLeaf: leaf, in: recordID, session: session)
        })
        .frame(maxWidth: .infinity)
        // A few notes fit as they are; more scroll inside a fixed height.
        let scrolls = item.node.allLeafNames().count > 4
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.isExam ? "\(item.node.title) · \(session.label)" : item.node.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Hecho", action: close)
                    .fontWeight(.semibold)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            if scrolls {
                ScrollView { content }
                    .frame(height: 260)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                content
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }
}

/// What every input needs to read and write grades for the sitting on screen.
private struct PartContext {
    let record: SubjectRecord
    let session: Convocatoria
    let inputs: [String: Double]
    var focus: FocusState<String?>.Binding
    let onEntry: (String, GradeEntry?) -> Void
}

/// The inputs inside a part: a single field for a grade, a compact grid for a group of many small
/// grades, or labelled rows (nested as needed) for anything else.
private struct PartContent: View {
    let node: Node
    let context: PartContext

    var body: some View {
        if let grade = node.asGrade {
            LeafInput(grade: grade, context: context, compact: false)
        } else if let group = node.asGroup {
            let allGrades = group.children.allSatisfy { $0.node.asGrade != nil }
            if allGrades && group.children.count >= 4 {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 10)], spacing: 10) {
                    ForEach(group.children) { child in
                        if let grade = child.node.asGrade {
                            VStack(spacing: 4) {
                                Text(Self.shortName(grade.name))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                LeafInput(grade: grade, context: context, compact: true)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Color(.quaternarySystemFill), in: .rect(cornerRadius: 12))
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(grade.name)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.children) { child in
                        if let grade = child.node.asGrade {
                            HStack(alignment: .firstTextBaseline) {
                                Text(grade.name)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                LeafInput(grade: grade, context: context, compact: false)
                                    .fixedSize()
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(child.node.title)
                                    .font(.subheadline.weight(.semibold))
                                PartContent(node: child.node, context: context)
                                    .padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        } else {
            Text("Este tipo de parte todavía no se puede rellenar desde aquí.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// "Prueba 10" → "P10", anything else → its first few letters, so a grid cell stays narrow.
    static func shortName(_ name: String) -> String {
        let words = name.split(separator: " ")
        if words.count >= 2, let last = words.last, Int(last) != nil, let first = words.first?.first {
            return "\(first)\(last)"
        }
        return String(name.prefix(7))
    }
}

/// The input for one grade, shaped by how the teacher gives it: a clean number field with its
/// scale shown beside it (changing the scale is done in the editor), or letter chips. In the
/// extraordinary sitting, a grade carried over from the ordinary one shows as such until re-entered.
private struct LeafInput: View {
    let grade: Grade
    let context: PartContext
    let compact: Bool

    @State private var text = ""

    private var fieldID: String { "\(context.session.rawValue)/\(grade.name)" }
    private var isFocused: Bool { context.focus.wrappedValue == fieldID }
    private var entry: GradeEntry? { context.record.entry(for: grade.name, in: context.session) }
    private var isCarriedOver: Bool { context.record.isCarriedOver(grade.name, in: context.session) }
    /// Can't be taken again: the ordinary grade stands in the extraordinary and can't be changed.
    private var isLocked: Bool { context.session == .extraordinary && context.record.isLockedInExtraordinary(grade.name) }
    private var isPercent: Bool { grade.inputStyle == .percent }
    private var limit: Double { isPercent ? 100 : grade.scaleMax }
    private var exceedsLimit: Bool { (Self.parse(text) ?? 0) > limit }
    private var overridesKeptGrade: Bool {
        context.session == .extraordinary
            && context.record.keepsForExtraordinary(grade.name)
            && context.record.extraordinaryEntries[grade.name] != nil
            && context.record.entries[grade.name] != nil
    }

    var body: some View {
        VStack(alignment: compact ? .center : .trailing, spacing: 4) {
            input
                .disabled(isLocked)
            if isLocked {
                Text("No se recupera")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isCarriedOver {
                Text("De la ordinaria")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if overridesKeptGrade, !compact {
                Button("Volver a la de la ordinaria") { context.onEntry(grade.name, nil) }
                    .font(.caption)
            }
        }
        .onAppear(perform: seed)
        .onChange(of: entry) {
            if context.focus.wrappedValue != fieldID { seed() }
        }
    }

    @ViewBuilder
    private var input: some View {
        switch grade.inputStyle ?? .points {
        case .letters(let scale):
            LetterInput(scale: scale, selected: entry?.letter, compact: compact) { letter in
                context.onEntry(grade.name, letter.map { GradeEntry(value: $0.value, outOf: 10, letter: $0.letter) })
            }
        case .percent:
            HStack(spacing: 6) {
                valueField
                suffix("%")
            }
        case .points:
            HStack(spacing: 6) {
                valueField
                if !compact { suffix("/ \(Self.format(grade.scaleMax))") }
            }
        }
    }

    private func suffix(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
    }

    private var valueField: some View {
        TextField("–", text: $text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .font((compact ? Font.title3 : Font.title).weight(.semibold).monospacedDigit())
            .foregroundStyle(exceedsLimit ? .red : (isCarriedOver ? .secondary : .primary))
            .frame(width: compact ? 56 : 96, height: compact ? 40 : 52)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 0.8 : 0), lineWidth: 1.5)
            }
            .accessibilityLabel(grade.name)
            .focused(context.focus, equals: fieldID)
            .onChange(of: text) {
                guard context.focus.wrappedValue == fieldID else { return }
                if isPercent { commitPercent() } else { commitPoints() }
            }
    }

    /// Shows what's stored on this grade's own scale, whatever scale it was typed on.
    private func seed() {
        guard let entry, entry.outOf > 0 else {
            text = ""
            return
        }
        text = Self.format(isPercent ? entry.value / entry.outOf * 100 : entry.value / entry.outOf * grade.scaleMax)
    }

    private func commitPoints() {
        guard let value = Self.parse(text) else {
            if text.isEmpty { context.onEntry(grade.name, nil) }
            return
        }
        context.onEntry(grade.name, GradeEntry(value: value, outOf: grade.scaleMax))
    }

    private func commitPercent() {
        guard let value = Self.parse(text) else {
            if text.isEmpty { context.onEntry(grade.name, nil) }
            return
        }
        context.onEntry(grade.name, GradeEntry(value: value, outOf: 100))
    }

    /// A plain non-negative number with a comma or a point — not "nan", "inf" or "1e999", which a
    /// pasted text or a hardware keyboard could otherwise sneak past the decimal pad.
    private static func parse(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty, normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(normalized), value.isFinite
        else { return nil }
        return value
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// Letter grades as chips (or a menu when space is tight); tapping the selected one clears it.
private struct LetterInput: View {
    let scale: [LetterGrade]
    let selected: String?
    let compact: Bool
    let onSelect: (LetterGrade?) -> Void

    var body: some View {
        if compact {
            Menu {
                ForEach(scale) { letter in
                    Button("\(letter.letter) (\(letter.value.formatted()))") { onSelect(letter) }
                }
                if selected != nil {
                    Button("Quitar", role: .destructive) { onSelect(nil) }
                }
            } label: {
                Text(selected ?? "—")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56)
            }
        } else {
            HStack(spacing: 6) {
                ForEach(scale) { letter in
                    let isSelected = letter.letter == selected
                    Button {
                        onSelect(isSelected ? nil : letter)
                    } label: {
                        Text(letter.letter)
                            .font(.headline)
                            .frame(minWidth: 36, minHeight: 36)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(letter.letter), \(letter.value.formatted()) sobre 10")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}

extension SubjectRecord {
    /// A note as it was given: its letter, a percentage, or points ("8,5", or "1,7 / 2" off 10).
    func displayedEntry(for grade: Grade, in session: Convocatoria) -> String {
        guard let entry = entry(for: grade.name, in: session), entry.value.isFinite, entry.outOf.isFinite, entry.outOf > 0 else { return "—" }
        let number = { (value: Double) in value.formatted(.number.precision(.fractionLength(0...2))) }
        if let letter = entry.letter { return letter }
        switch grade.inputStyle ?? .points {
        case .percent:
            return "\(number(entry.outOf == 100 ? entry.value : entry.value / entry.outOf * 100)) %"
        case .points, .letters:
            return entry.outOf == 10 ? number(entry.value) : "\(number(entry.value)) / \(number(entry.outOf))"
        }
    }
}
