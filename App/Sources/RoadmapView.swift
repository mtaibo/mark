import SwiftUI

/// One planned version and what it brings.
struct RoadmapVersion: Identifiable {
    let title: String
    let subtitle: String
    let items: [String]

    var id: String { title }

    /// Written here for now; it'll be downloaded from migueltaibo.com so it can change without an
    /// app update.
    static let all = [
        RoadmapVersion(title: "Versión 1", subtitle: "Llegada a la App Store", items: [
            "Pantalla de cuenta renovada: tus estudios, tu expediente y tus datos, cada uno en su sitio.",
            "Calendario rediseñado para ver antes lo que tienes pendiente.",
            "Pantalla de asignatura más clara: el resumen de notas, el examen final y la forma de poner las notas.",
            "Editor de fórmulas más cómodo.",
        ]),
        RoadmapVersion(title: "Versión 2", subtitle: "Asistente de IA", items: [
            "Pásale la guía docente y configura la asignatura solo.",
            "Cuéntale las reglas («si saco menos de un 4 en tal parte, la otra no hace media») y hace los cambios sin entrar al editor.",
        ]),
        RoadmapVersion(title: "Versión 3", subtitle: "Plantillas de la comunidad", items: [
            "Publica la configuración de tus asignaturas para que tus compañeros la descarguen como plantilla y la editen.",
            "Cuentas de usuario para compartir plantillas.",
        ]),
        RoadmapVersion(title: "Más adelante", subtitle: "Sin fecha todavía", items: [
            "Una bienvenida al abrir la app por primera vez para elegir qué estudias.",
            "Instituto y otros estudios, además de la universidad.",
            "Sincronización con iCloud entre tus dispositivos.",
        ]),
    ]
}

/// "Próximas implementaciones", from the account tab: what's planned, version by version.
struct RoadmapView: View {
    var body: some View {
        List {
            ForEach(RoadmapVersion.all) { version in
                Section {
                    ForEach(version.items, id: \.self) { item in
                        Label(item, systemImage: "circle")
                            .labelStyle(RoadmapItemStyle())
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(version.subtitle)
                    }
                    .textCase(nil)
                }
            }
        }
        .navigationTitle("Próximas implementaciones")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A small dot in front of each planned item, top-aligned so long lines wrap under the text.
private struct RoadmapItemStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(.tint)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            configuration.title
        }
    }
}
