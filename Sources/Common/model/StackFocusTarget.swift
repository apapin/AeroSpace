public enum StackFocusTarget: String, CaseIterable, Equatable, Sendable {
    case stackPrev = "stack-prev"
    case stackNext = "stack-next"
    case stackFirst = "stack-first"
    case stackLast = "stack-last"
    case stackRecent = "stack-recent"
}

public enum FocusDirection: Equatable, Sendable {
    case direction(CardinalDirection)
    case dfsRelative(DfsNextPrev)
    case stack(StackFocusTarget)
}

extension FocusDirection: CaseIterable {
    public static var allCases: [FocusDirection] {
        CardinalDirection.allCases.map { .direction($0) }
            + DfsNextPrev.allCases.map { .dfsRelative($0) }
            + StackFocusTarget.allCases.map { .stack($0) }
    }
}

extension FocusDirection: RawRepresentable {
    public typealias RawValue = String

    public init?(rawValue: RawValue) {
        if let direction = CardinalDirection(rawValue: rawValue) {
            self = .direction(direction)
        } else if let nextPrev = DfsNextPrev(rawValue: rawValue) {
            self = .dfsRelative(nextPrev)
        } else if let stackTarget = StackFocusTarget(rawValue: rawValue) {
            self = .stack(stackTarget)
        } else {
            return nil
        }
    }

    public var rawValue: RawValue {
        switch self {
            case .direction(let direction): direction.rawValue
            case .dfsRelative(let nextPrev): nextPrev.rawValue
            case .stack(let target): target.rawValue
        }
    }
}
