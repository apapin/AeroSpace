import AppKit
import Common

struct SwapCommand: Command {
    let args: SwapCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else {
            return .fail
        }

        guard let currentWindow = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }

        let targetWindow: Window?
        switch args.target.val {
            case .direction(let direction):
                switch currentWindow.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    case let (parent, ownIndex)?:
                        targetWindow = parent.children[ownIndex + direction.focusOffset].findLeafWindowRecursive(snappedTo: direction.opposite)
                    case nil where args.wrapAround:
                        targetWindow = target.workspace.findLeafWindowRecursive(snappedTo: direction.opposite)
                    case nil:
                        return .fail
                }
            case .dfsRelative(let nextPrev):
                let windows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
                targetWindow = findDfsSwapTarget(
                    in: windows,
                    from: currentWindow,
                    nextPrev: nextPrev,
                    wrapAround: args.wrapAround,
                )
        }

        guard let targetWindow else {
            return .fail
        }

        swapBspSlots(mruDominant: currentWindow, targetWindow)

        if args.swapFocus {
            return .from(bool: targetWindow.focusWindow())
        }
        return .succ
    }
}

@MainActor
private func findDfsSwapTarget(
    in windows: [Window],
    from currentWindow: Window,
    nextPrev: DfsNextPrev,
    wrapAround: Bool,
) -> Window? {
    guard let currentIndex = windows.firstIndex(of: currentWindow) else { return nil }

    let step = nextPrev == .dfsNext ? 1 : -1
    var candidateIndex = currentIndex
    for _ in 0 ..< windows.count {
        candidateIndex += step
        if !windows.indices.contains(candidateIndex) {
            guard wrapAround else { return nil }
            candidateIndex = (candidateIndex + windows.count) % windows.count
        }

        let candidate = windows[candidateIndex]
        if candidate.bspSlot !== currentWindow.bspSlot {
            return candidate
        }
    }
    return nil
}
