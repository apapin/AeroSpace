import AppKit
import Common
import Foundation

struct BalanceSizesCommand: Command {
    let args: BalanceSizesCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        // Learned minimum sizes only grow; balancing re-measures them so a
        // window gives back space its app no longer needs.
        for window in target.workspace.allLeafWindowsRecursive {
            window.forgetMinimumTilingSize()
        }
        balance(target.workspace.rootTilingContainer)
        return .succ
    }
}

@MainActor
private func balance(_ parent: TilingContainer) {
    for child in parent.children {
        switch parent.layout {
            case .tiles: child.setWeight(parent.orientation, 1)
            case .accordion, .stack: break // Do nothing
        }
        if let child = child as? TilingContainer {
            balance(child)
        }
    }
}
