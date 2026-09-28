import AVFoundation
import Testing

@testable import HarkCore

@Suite struct MicPermissionTests {
    @Test(arguments: [
        (AVAudioApplication.recordPermission.granted, MicPermissionStatus.granted),
        (.denied, .denied),
        (.undetermined, .undetermined),
    ])
    func status(_ permission: AVAudioApplication.recordPermission, _ expected: MicPermissionStatus) {
        #expect(MicPermission.status(for: permission) == expected)
    }

    @Test func unknownFutureCaseIsUndetermined() throws {
        let future = try #require(AVAudioApplication.recordPermission(rawValue: 0x7A7A_7A7A))
        #expect(MicPermission.status(for: future) == .undetermined)
    }
}
