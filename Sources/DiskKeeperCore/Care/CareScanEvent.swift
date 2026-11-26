import Foundation

/// Events of one Care Scan. Contract: `started` first (once); exactly one terminal event (`finished` or
/// `cancelled`) last, after which the stream ends. Stages are strictly sequential: a stage's events sit between
/// its `stageStarted` and its `stageFinished`/`stageFailed`.
public enum CareScanEvent: Sendable {
    public enum SkipReason: String, Sendable, Hashable { case needsTree, disabled }

    case started(id: UUID, stages: [CareStage], at: Date)
    case stageStarted(CareStage)
    case stageProgress(CareStage, Double?)
    case scanEvent(CareStage, ScanEvent)
    /// Every item a stage delivers, including ones the report totals skip as already counted (see `CareReport`).
    case item(CareStage, ScanItem)
    case warning(CareStage, ScanWarning)
    case artifact(CareArtifact)
    case stageFinished(CareStage, [ModuleSummary])
    /// Kind `.scannerFailed`; the other stages continue.
    case stageFailed(CareStage, ScanWarning)
    case stageSkipped(CareStage, reason: SkipReason)
    case finished(CareReport)
    /// Partial; `wasCancelled == true`.
    case cancelled(CareReport)
}
