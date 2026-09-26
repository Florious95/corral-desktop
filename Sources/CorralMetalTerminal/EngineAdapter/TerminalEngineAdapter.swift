import CorralContracts

/// Kernel adapters implement only the typed engine/snapshot boundary; terminal replies stay local.
public protocol TerminalEngineAdapter: TerminalEngineSubmitting, TerminalSnapshotProviding {}
