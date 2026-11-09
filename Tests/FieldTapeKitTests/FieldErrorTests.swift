import Foundation
import Testing
@testable import FieldTapeKit

@Suite struct FieldErrorTests {
    @Test func mapsTheMTPLayer() throws {
        let refused = try #require(FieldError.wrapping(MTPError.refused(.getObject, responseCode: 0x2009)) as? FieldError)
        #expect(refused.code == .deviceRefused)
        #expect(refused.responseCode == 0x2009)
        #expect(refused.changed.isEmpty)
        #expect(refused.errorDescription == "The OP-1 refused the request (response 0x2009).")

        #expect((FieldError.wrapping(MTPError.timedOut(.getObject)) as? FieldError)?.code == .timedOut)
        #expect((FieldError.wrapping(MTPError.disconnected) as? FieldError)?.code == .disconnected)

        let unreadable = try #require(FieldError.wrapping(MTPError.unreadableResponse(.getObject)) as? FieldError)
        #expect(unreadable.code == .deviceRefused)
        #expect(unreadable.responseCode == nil)
        #expect(unreadable.errorDescription == "The OP-1 sent a reply that couldn't be read.")

        #expect((FieldError.wrapping(PTPError.truncated(offset: 3)) as? FieldError)?.code == .deviceRefused)
    }

    @Test func passesThroughCancellationAndFieldErrors() {
        #expect(FieldError.wrapping(CancellationError()) is CancellationError)
        #expect((FieldError.wrapping(FieldError(.notAuthorized)) as? FieldError)?.code == .notAuthorized)
    }

    @Test(arguments: [FieldError.Code.disconnected, .timedOut, .notAuthorized, .deviceInUse])
    func everyCodeExplainsItselfAndWhatToDo(code: FieldError.Code) {
        let error = FieldError(code)
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.recoverySuggestion?.isEmpty == false)
    }
}
