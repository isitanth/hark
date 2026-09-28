import Foundation

public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }
}
