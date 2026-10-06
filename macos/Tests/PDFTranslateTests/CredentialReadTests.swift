import Foundation
import XCTest
@testable import PDFTranslate

final class CredentialReadTests: XCTestCase {
    func testCancelledQueuedReadNeverInvokesOperation() async throws {
        let queue = DispatchQueue(label: "CredentialReadTests.blocked")
        let release = DispatchSemaphore(value: 0)
        let occupied = expectation(description: "Read queue is occupied")
        queue.async { occupied.fulfill(); release.wait() }
        await fulfillment(of: [occupied], timeout: 2)
        let invoked = expectation(description: "Cancelled operation must not run")
        invoked.isInverted = true
        let task = Task {
            try await CredentialReadScheduler.perform(timeout: 2, queue: queue) {
                invoked.fulfill()
                return "unexpected"
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reads must throw") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, received \(error)") }
        release.signal()
        await fulfillment(of: [invoked], timeout: 0.1)
    }

    func testCancellingInFlightReadReturnsBeforeOperationAndIgnoresLateResult() async throws {
        let queue = DispatchQueue(label: "CredentialReadTests.cancelled", attributes: .concurrent)
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "Read started")
        let task = Task {
            try await CredentialReadScheduler.perform(timeout: 2, queue: queue) {
                started.fulfill()
                release.wait()
                return "late value"
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reads must throw") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, received \(error)") }
        // Completing the synchronous work later must not resume the checked continuation twice.
        release.signal()
        let drained = expectation(description: "Late callback drained")
        queue.async(flags: .barrier) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    func testDeadlineReturnsBeforeOperationAndIgnoresLateResult() async throws {
        let queue = DispatchQueue(label: "CredentialReadTests.deadline", attributes: .concurrent)
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "Read started")
        let task = Task {
            try await CredentialReadScheduler.perform(timeout: 0.2, queue: queue) {
                started.fulfill()
                release.wait()
                return "late value"
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await task.value; XCTFail("Read must reach its deadline") }
        catch CredentialAccessError.timedOut { }
        catch { XCTFail("Expected deadline, received \(error)") }
        release.signal()
        let drained = expectation(description: "Late callback drained")
        queue.async(flags: .barrier) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}
