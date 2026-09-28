import Foundation
import HarkCore
import Testing

/// Resume data names the partial file the transport kept; `discardResumeData` deletes it. Deleting is the part
/// that has to be right, so these pin both what is found and what is refused.
@Suite struct ResumeDataTests {
    /// The shape of a real blob, captured on macOS 27 on 2026-09-21: an `NSKeyedArchiver` archive whose
    /// `$objects` holds the key `NSURLSessionResumeInfoTempFileName` and, separately, the bare file name.
    private func archive(objects: [Any]) throws -> Data {
        let plist: [String: Any] = [
            "$archiver": "NSKeyedArchiver", "$version": 100_000, "$top": ["root": 1], "$objects": objects,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    @Test func theTemporaryFileNameIsFoundInsideARealShapedArchive() throws {
        let data = try archive(objects: [
            "$null", "NSURLSessionResumeInfoTempFileName", "NSURLSessionResumeBytesReceived",
            "CFNetworkDownload_DVxcma.tmp",
        ])
        #expect(URLSessionDownloader.temporaryFileName(in: data) == "CFNetworkDownload_DVxcma.tmp")
    }

    /// The name is used to build a path to delete. Anything that is not a plain name in the temp directory
    /// must be ignored, so a crafted blob cannot aim the delete somewhere else.
    @Test(
        arguments: [
            "../CFNetworkDownload_x.tmp",
            "/etc/CFNetworkDownload_x.tmp",
            "CFNetworkDownload_x/../../y.tmp",
            "somethingElse.tmp",
            "CFNetworkDownload_x.bin",
        ])
    func anythingButAPlainTempNameIsRefused(_ name: String) throws {
        let data = try archive(objects: ["$null", name])
        #expect(URLSessionDownloader.temporaryFileName(in: data) == nil)
    }

    @Test func dataThatIsNotAnArchiveNamesNothing() {
        #expect(URLSessionDownloader.temporaryFileName(in: Data("not a plist".utf8)) == nil)
        #expect(URLSessionDownloader.temporaryFileName(in: Data()) == nil)
    }

    @Test func discardingDeletesTheNamedFileAndNothingElse() throws {
        let temp = FileManager.default.temporaryDirectory
        let target = temp.appending(path: "CFNetworkDownload_HarkTest\(UUID().uuidString.prefix(6)).tmp")
        let bystander = temp.appending(path: "CFNetworkDownload_Other\(UUID().uuidString.prefix(6)).tmp")
        try Data("partial".utf8).write(to: target)
        try Data("someone else's".utf8).write(to: bystander)
        defer { try? FileManager.default.removeItem(at: bystander) }

        URLSessionDownloader().discardResumeData(try archive(objects: ["$null", target.lastPathComponent]))

        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: bystander.path(percentEncoded: false)))
    }
}
