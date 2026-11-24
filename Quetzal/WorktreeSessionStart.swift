import Foundation
import Observation

@MainActor @Observable
final class WorktreeSessionStart {
    private struct Attempt {
        let id = UUID()
        let selection: WorktreeSelection
    }

    var selection: WorktreeSelection?
    private(set) var error: String?
    private var attempt: Attempt?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isStarting: Bool { attempt != nil }

    func begin() -> UUID? {
        guard attempt == nil, let selection else { return nil }
        let next = Attempt(selection: selection)
        attempt = next
        error = nil
        return next.id
    }

    func finish(_ id: UUID, error: String? = nil) {
        guard isCurrent(id) else { return }
        invalidate()
        self.error = error
    }

    func repositoryOpened() {
        invalidate()
        selection = nil
        error = nil
    }

    func selectionChanged() {
        if selection != nil { error = nil }
    }

    func invalidate() {
        task?.cancel()
        task = nil
        attempt = nil
    }

    @discardableResult
    func validateAndStart(
        _ id: UUID,
        validate: @escaping (WorktreeSelection) async throws -> URL,
        launch: @escaping (URL) async -> Void
    ) -> Task<Void, Never>? {
        guard isCurrent(id), let selection = attempt?.selection, task == nil else { return nil }
        let verification = Task {
            do {
                let directory = try await validate(selection)
                guard !Task.isCancelled, isCurrent(id) else { return }
                task = nil
                attempt = nil
                await launch(directory)
            } catch {
                guard !Task.isCancelled, isCurrent(id) else { return }
                task = nil
                attempt = nil
                self.selection = nil
                self.error = error.localizedDescription
            }
        }
        task = verification
        return verification
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard let attempt else { return false }
        return attempt.id == id && attempt.selection.id == selection?.id
    }
}
