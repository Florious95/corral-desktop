import CorralContracts

public protocol TerminalRendering: Sendable {
    func present(_ snapshot: TerminalGridSnapshot, in viewport: StageViewportRect, dirtyGeneration: DirtyGeneration) async
    func setSleepState(_ state: RenderSleepState) async
}
