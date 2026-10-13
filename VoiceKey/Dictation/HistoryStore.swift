import Foundation

struct HistoryRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let raw: String
    let text: String
    let seconds: Double
    let source: String
    let asrModel: String
    let llmModel: String
}

/// 历史记录落盘在 App 沙盒 Documents 下（不放进 App Group，避免键盘侧可见）。
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []

    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = base.appendingPathComponent("history.json")
        load()
    }

    func add(_ record: HistoryRecord) {
        records.insert(record, at: 0)
        if records.count > 500 { records = Array(records.prefix(500)) }
        save()
    }

    func delete(_ record: HistoryRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
