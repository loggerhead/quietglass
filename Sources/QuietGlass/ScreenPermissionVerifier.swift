import Foundation
import ScreenCaptureKit

/// Checks access by enumerating shareable content, without capturing frames or
/// creating another capture pipeline. Late results cannot overwrite newer checks.
@MainActor final class ScreenPermissionVerifier {
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = 0
    private let check: @MainActor () async throws -> Bool
    var isChecking: Bool { task != nil }

    init(check: @escaping @MainActor () async throws -> Bool = {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return !content.displays.isEmpty
    }) { self.check = check }

    func start(completed: @escaping @MainActor (Bool?) -> Void) {
        guard !isChecking else { return }
        generation += 1
        let token = generation
        task = Task { [weak self, check] in
            let result: Bool?
            do { result = try await check() ? true : nil }
            catch {
                let failure = error as NSError
                result = failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue ? false : nil
            }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.cancel()
            completed(result)
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.generation == token else { return }
            self.cancel()
            completed(nil)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        timeout?.cancel(); timeout = nil
    }
}
