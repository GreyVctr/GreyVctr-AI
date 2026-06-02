import Foundation

/// Manages history list state: loading, displaying, and deleting history entries.
@Observable
final class HistoryViewModel {

    // MARK: - Published State

    /// All history entries, sorted by timestamp descending (newest first).
    var entries: [HistoryEntry] = []

    // MARK: - Dependencies

    private let historyStore: HistoryStoreProtocol

    // MARK: - Init

    /// Creates the view model with a history store dependency.
    /// - Parameter historyStore: The persistence store for history entries.
    init(historyStore: HistoryStoreProtocol) {
        self.historyStore = historyStore
    }

    // MARK: - Actions

    /// Load all history entries from the store.
    ///
    /// Replaces the current `entries` with the latest data from `HistoryStore.fetchAll()`.
    func loadHistory() {
        entries = historyStore.fetchAll()
    }

    /// Delete a specific history entry and refresh the list.
    ///
    /// - Parameter entry: The entry to delete.
    func deleteEntry(_ entry: HistoryEntry) {
        do {
            try historyStore.delete(entry: entry)
        } catch {
            // Deletion errors are logged by HistoryStore; refresh the list regardless
        }
        loadHistory()
    }

    /// Delete all history entries and refresh the list.
    func deleteAll() {
        do {
            try historyStore.deleteAll()
        } catch {
            // Deletion errors are logged by HistoryStore; refresh the list regardless
        }
        loadHistory()
    }
}
