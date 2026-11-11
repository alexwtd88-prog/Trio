import Foundation

/// One CGM sensor (or, for G5/G6, one sensor session on a transmitter) that
/// connected to Trio. Record-keeping only: nothing here is read by the
/// algorithm, glucose storage, or any dosing path.
struct SensorHistoryEntry: JSON, Identifiable, Equatable {
    var id: String
    /// Identifier the CGM reports over Bluetooth. For G7 / ONE+ this is the
    /// advertised sensor name (e.g. "DXCM4F"); for G5/G6 it is the transmitter ID.
    /// It is NOT the 12-digit serial printed on the sensor box/applicator.
    var sensorName: String
    /// Human-readable CGM type, e.g. "Dexcom G7", "Dexcom ONE+", "Dexcom G6".
    var sensorType: String
    /// Sensor activation / session start as reported by the CGM.
    var activatedAt: Date
    /// First time Trio saw this sensor.
    var firstSeenAt: Date
    /// Most recent time Trio received a reading from this sensor.
    var lastSeenAt: Date
    /// When Trio saw a different sensor start (i.e. this sensor was replaced).
    var replacedAt: Date?
    /// Session length reported by the CGM, if known.
    var expectedLifetime: TimeInterval?
    /// Printed serial number, entered manually by the user (not available over Bluetooth).
    var printedSerial: String?
    var notes: String?

    /// Days from activation to the last reading Trio received.
    var daysLasted: Double {
        max(0, lastSeenAt.timeIntervalSince(activatedAt)) / 86400
    }

    var isCurrent: Bool { replacedAt == nil }

    func matches(name: String, activatedAt other: Date) -> Bool {
        sensorName == name && abs(activatedAt.timeIntervalSince(other)) < 60 * 60
    }
}

/// Stores the history of CGM sensors in `freeaps/sensor_history.json`.
/// All failures are swallowed and logged; this must never interfere with CGM
/// data flow.
final class SensorHistoryStore: ObservableObject {
    static let shared = SensorHistoryStore()

    @Published private(set) var entries: [SensorHistoryEntry] = []

    private let storage: FileStorage
    private let queue = DispatchQueue(label: "SensorHistoryStore.queue", qos: .utility)
    private var cache: [SensorHistoryEntry] = []
    private var loaded = false

    /// Only rewrite the file for a "still alive" update this often.
    private let lastSeenWriteInterval: TimeInterval = 15 * 60
    private let maxEntries = 500

    init(storage: FileStorage = BaseFileStorage()) {
        self.storage = storage
        queue.async { self.loadIfNeeded() }
    }

    private func loadIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !loaded else { return }
        loaded = true
        cache = storage.retrieve(OpenAPS.Trio.sensorHistory, as: [SensorHistoryEntry].self) ?? []
        publish()
    }

    private func publish() {
        let sorted = cache.sorted { $0.activatedAt > $1.activatedAt }
        DispatchQueue.main.async { self.entries = sorted }
    }

    private func persist() {
        if cache.count > maxEntries {
            cache = Array(cache.sorted { $0.activatedAt > $1.activatedAt }.prefix(maxEntries))
        }
        storage.save(cache, as: OpenAPS.Trio.sensorHistory)
        publish()
    }

    /// Record that a sensor is connected / producing data. Safe to call on every reading.
    func observe(
        sensorName: String?,
        sensorType: String,
        activatedAt: Date?,
        expectedLifetime: TimeInterval? = nil,
        seenAt now: Date = Date()
    ) {
        guard let sensorName = sensorName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sensorName.isEmpty, sensorName != "Unknown",
              let activatedAt = activatedAt,
              activatedAt <= now.addingTimeInterval(60 * 60) // ignore future-dated sessions
        else { return }

        queue.async {
            self.loadIfNeeded()

            if let index = self.cache.firstIndex(where: { $0.matches(name: sensorName, activatedAt: activatedAt) }) {
                var entry = self.cache[index]
                let lifetimeChanged = expectedLifetime != nil && entry.expectedLifetime != expectedLifetime
                guard lifetimeChanged || now.timeIntervalSince(entry.lastSeenAt) >= self.lastSeenWriteInterval else { return }
                entry.lastSeenAt = max(entry.lastSeenAt, now)
                if let expectedLifetime = expectedLifetime { entry.expectedLifetime = expectedLifetime }
                self.cache[index] = entry
                self.persist()
                return
            }

            // A new sensor: mark older open sensors as replaced.
            for index in self.cache.indices where self.cache[index].replacedAt == nil && self.cache[index].activatedAt < activatedAt {
                self.cache[index].replacedAt = activatedAt
            }

            let entry = SensorHistoryEntry(
                id: UUID().uuidString,
                sensorName: sensorName,
                sensorType: sensorType,
                activatedAt: activatedAt,
                firstSeenAt: now,
                lastSeenAt: max(now, activatedAt),
                replacedAt: nil,
                expectedLifetime: expectedLifetime,
                printedSerial: nil,
                notes: nil
            )
            self.cache.append(entry)
            debug(.deviceManager, "Sensor history: recorded new \(sensorType) sensor \(sensorName) activated \(activatedAt)")
            self.persist()
        }
    }

    func update(_ entry: SensorHistoryEntry) {
        queue.async {
            self.loadIfNeeded()
            guard let index = self.cache.firstIndex(where: { $0.id == entry.id }) else { return }
            self.cache[index].printedSerial = entry.printedSerial?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.cache[index].notes = entry.notes
            self.persist()
        }
    }

    func delete(ids: [String]) {
        queue.async {
            self.loadIfNeeded()
            self.cache.removeAll { ids.contains($0.id) }
            self.persist()
        }
    }

    // MARK: - Export

    static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter
    }()

    static func summary(for entry: SensorHistoryEntry) -> String {
        let format = exportDateFormatter
        var lines = [
            "\(entry.sensorType) sensor",
            "Bluetooth sensor ID: \(entry.sensorName)"
        ]
        if let serial = entry.printedSerial, !serial.isEmpty {
            lines.append("Serial number: \(serial)")
        }
        lines.append("Activated: \(format.string(from: entry.activatedAt))")
        lines.append("Last reading: \(format.string(from: entry.lastSeenAt))")
        if let replacedAt = entry.replacedAt {
            lines.append("Replaced: \(format.string(from: replacedAt))")
        }
        lines.append(String(format: "Days lasted: %.1f", entry.daysLasted))
        if let notes = entry.notes, !notes.isEmpty {
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    static func csv(for entries: [SensorHistoryEntry]) -> String {
        func field(_ value: String?) -> String {
            let value = value ?? ""
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let format = exportDateFormatter
        var rows = ["Sensor type,Bluetooth sensor ID,Serial number,Activated,Last reading,Replaced,Days lasted,Notes"]
        for entry in entries {
            rows.append([
                field(entry.sensorType),
                field(entry.sensorName),
                field(entry.printedSerial),
                field(format.string(from: entry.activatedAt)),
                field(format.string(from: entry.lastSeenAt)),
                field(entry.replacedAt.map { format.string(from: $0) }),
                String(format: "%.1f", entry.daysLasted),
                field(entry.notes)
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}
