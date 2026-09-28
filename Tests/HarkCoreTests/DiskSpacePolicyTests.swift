import Foundation
import HarkCore
import Testing

@Suite struct DiskSpacePolicyTests {
    private func policy(available: Int64?) -> DiskSpacePolicy {
        DiskSpacePolicy { _ in available }
    }

    @Test func weightsAreChargedOnceAndAZipTwice() {
        let entry = ModelCatalog.entry(for: .small)
        #expect(DiskSpacePolicy.requiredBytes(for: entry.weights) == 264_464_607)
        #expect(DiskSpacePolicy.requiredBytes(for: entry.coreMLEncoder!) == 163_083_239 * 2)
    }

    @Test(arguments: ModelTier.allCases)
    func aTierCostsItsWeightsPlusTwiceItsEncoder(_ tier: ModelTier) throws {
        let entry = ModelCatalog.entry(for: tier)
        let encoder = try #require(entry.coreMLEncoder)
        #expect(DiskSpacePolicy.requiredBytes(for: entry) == entry.weights.byteCount + encoder.byteCount * 2)
        #expect(DiskSpacePolicy.requiredBytes(for: entry) > entry.downloadByteCount)
    }

    @Test func roomToSpare() throws {
        let directory = try TemporaryDirectory()
        #expect(policy(available: 1_000).check(999, at: directory.url) == nil)
        #expect(policy(available: 1_000).check(1_000, at: directory.url) == nil)
    }

    @Test func oneByteShortIsARefusalCarryingBothNumbers() throws {
        let directory = try TemporaryDirectory()
        #expect(
            policy(available: 999).check(1_000, at: directory.url)
                == .insufficientSpace(required: 1_000, available: 999))
        #expect(policy(available: 0).check(1, at: directory.url) == .insufficientSpace(required: 1, available: 0))
    }

    @Test func aVolumeThatWillNotSayIsNotAReasonToRefuse() throws {
        let directory = try TemporaryDirectory()
        #expect(policy(available: nil).check(Int64.max, at: directory.url) == nil)
    }

    @Test func theRealMeasurementAnswersForADirectoryThatDoesNotExistYet() throws {
        let directory = try TemporaryDirectory()
        let models = directory.url.appending(path: "models/.staging", directoryHint: .isDirectory)
        let capacity = try #require(DiskSpacePolicy.volumeCapacity(models))
        #expect(capacity > 0)
        // Int64.max rather than capacity + 1: the latter races a second measurement, and any other test that
        // writes to the temp volume in parallel can free up that one byte in between.
        #expect(DiskSpacePolicy().check(.max, at: models) != nil)
    }
}
