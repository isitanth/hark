import Foundation
import HarkObjC
import Testing

/// The shim is the only thing between an AVFoundation assertion and the end of the process.
@Suite struct ObjCExceptionTests {
    @Test func raisedExceptionBecomesAnError() throws {
        let error = try #require(
            HarkCatchException {
                NSException(name: .invalidArgumentException, reason: "rate mismatch", userInfo: nil).raise()
            })
        #expect(error.localizedDescription == "rate mismatch")
    }

    @Test func errorCarriesDomainAndName() throws {
        let error = try #require(
            HarkCatchException {
                NSException(name: .invalidArgumentException, reason: "rate mismatch", userInfo: nil).raise()
            })
        let nsError = error as NSError
        #expect(nsError.domain == "HarkObjCException")
        #expect(nsError.code == 0)
        #expect(nsError.userInfo["name"] as? String == NSExceptionName.invalidArgumentException.rawValue)
    }

    @Test func blockThatDoesNotRaiseReturnsNilAndRan() {
        var ran = false
        let error = HarkCatchException { ran = true }
        #expect(error == nil)
        #expect(ran)
    }
}
