import SwiftUI
import UIKit

/// Read-only list of CGM sensors that have connected to Trio, with a manual
/// "printed serial" field and copy/share/export for warranty claims.
struct SensorHistoryView: View {
    @ObservedObject var store: SensorHistoryStore = .shared

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(
                footer: Text(
                    "Trio records each sensor when it connects. The Bluetooth sensor ID is not the serial number printed on the sensor box; tap a sensor to add the printed serial for replacement claims."
                )
            ) {
                if store.entries.isEmpty {
                    Text("No sensors recorded yet. Sensors are added here the next time Trio receives a reading.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.entries) { entry in
                        NavigationLink(destination: SensorHistoryDetailView(entry: entry, store: store)) {
                            SensorHistoryRow(entry: entry)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = SensorHistoryStore.summary(for: entry)
                            } label: {
                                Label("Copy Details", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    .onDelete { offsets in
                        store.delete(ids: offsets.map { store.entries[$0].id })
                    }
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Sensor History")
        .navigationBarTitleDisplayMode(.automatic)
        .toolbar {
            if !store.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: SensorHistoryStore.csv(for: store.entries),
                        subject: Text("Sensor History"),
                        preview: SharePreview("Sensor History (CSV)")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

private struct SensorHistoryRow: View {
    let entry: SensorHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.sensorType).bold()
                Text(entry.sensorName).foregroundColor(.secondary)
                Spacer()
                if entry.isCurrent {
                    Text("Current").font(.caption).foregroundColor(.green)
                }
            }
            if let serial = entry.printedSerial, !serial.isEmpty {
                Text("SN \(serial)").font(.footnote)
            }
            Text(
                "\(entry.activatedAt.formatted(date: .abbreviated, time: .shortened)) · \(String(format: "%.1f", entry.daysLasted)) days"
            )
            .font(.footnote)
            .foregroundColor(.secondary)
        }
    }
}

struct SensorHistoryDetailView: View {
    @State var entry: SensorHistoryEntry
    let store: SensorHistoryStore

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var serialBinding: Binding<String> {
        Binding(get: { entry.printedSerial ?? "" }, set: { entry.printedSerial = $0 })
    }

    private var notesBinding: Binding<String> {
        Binding(get: { entry.notes ?? "" }, set: { entry.notes = $0 })
    }

    var body: some View {
        List {
            Section(header: Text("Sensor")) {
                LabeledContent("Type", value: entry.sensorType)
                LabeledContent("Bluetooth sensor ID", value: entry.sensorName)
                LabeledContent("Activated", value: entry.activatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last reading", value: entry.lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                if let replacedAt = entry.replacedAt {
                    LabeledContent("Replaced", value: replacedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Days lasted", value: String(format: "%.1f", entry.daysLasted))
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("For Replacement Claims"),
                footer: Text("The serial number is printed on the sensor applicator label and box. It is not sent over Bluetooth, so enter it here.")
            ) {
                TextField("Printed serial number", text: serialBinding)
                    .keyboardType(.numberPad)
                TextField("Notes", text: notesBinding, axis: .vertical)
            }
            .listRowBackground(Color.chart)

            Section {
                Button {
                    UIPasteboard.general.string = SensorHistoryStore.summary(for: entry)
                } label: {
                    Label("Copy Details", systemImage: "doc.on.doc")
                }
                ShareLink(item: SensorHistoryStore.summary(for: entry)) {
                    Label("Share Details", systemImage: "square.and.arrow.up")
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(entry.sensorName)
        .onDisappear { store.update(entry) }
    }
}
