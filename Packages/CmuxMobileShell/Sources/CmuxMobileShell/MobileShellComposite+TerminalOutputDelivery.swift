import CMUXMobileCore
internal import CmuxMobileDiagnostics
import CmuxMobileShellModel
public import Foundation
internal import OSLog

nonisolated private let terminalOutputLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Yield a raw PTY byte chunk to the surface stream, if one is attached.
    func deliverTerminalBytes(_ bytes: Data, surfaceID: String) {
        deliverTerminalOutput(
            TerminalOutputDelivery(bytes: bytes, replaceable: false),
            surfaceID: surfaceID
        )
    }

    func deliverTerminalRenderGrid(_ frame: MobileTerminalRenderGridFrame, surfaceID: String) {
        deliverTerminalOutput(
            TerminalOutputDelivery(
                renderGrid: frame,
                replaceable: frame.isReplaceableViewportPatchForMobileDelivery
            ),
            surfaceID: surfaceID
        )
    }

    func deliverAuthoritativeTerminalRenderGrid(
        _ renderGrid: MobileTerminalRenderGridFrame,
        expectedSurfaceID: String? = nil,
        source: String
    ) {
        guard expectedSurfaceID == nil || renderGrid.surfaceID == expectedSurfaceID,
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return
        }
        if terminalReplayIDsInFlightBySurfaceID[renderGrid.surfaceID] != nil {
            bufferTerminalRenderGridFrameDuringReplay(renderGrid, source: source)
            return
        }
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           deliveredSeq > renderGrid.stateSeq {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale source=\(source) surface=\(renderGrid.surfaceID) delivered=\(deliveredSeq) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        markTerminalBytesDelivered(surfaceID: renderGrid.surfaceID, endSeq: renderGrid.stateSeq)
        deliverTerminalRenderGrid(renderGrid, surfaceID: renderGrid.surfaceID)
    }

    private func bufferTerminalRenderGridFrameDuringReplay(
        _ renderGrid: MobileTerminalRenderGridFrame,
        source: String
    ) {
        let surfaceID = renderGrid.surfaceID
        var frames = terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] ?? []
        if frames.count >= Self.maxRenderGridFramesBufferedDuringReplay {
            frames.removeFirst()
            terminalRenderGridReplayBufferDroppedSurfaceIDs.insert(surfaceID)
            MobileDebugLog.anchormux("sync.render_grid_replay_buffer_drop_oldest source=\(source) surface=\(surfaceID)")
            terminalOutputLog.warning("render-grid replay buffer dropped oldest frame source=\(source, privacy: .public) surface=\(surfaceID, privacy: .public)")
        }
        frames.append(renderGrid)
        terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] = frames
        MobileDebugLog.anchormux("sync.render_grid_buffered_during_replay source=\(source) surface=\(surfaceID) seq=\(renderGrid.stateSeq)")
    }

    func flushTerminalRenderGridFramesBufferedDuringReplay(
        surfaceID: String,
        replaySeq: UInt64?
    ) {
        let droppedFrames = terminalRenderGridReplayBufferDroppedSurfaceIDs.remove(surfaceID) != nil
        let frames = terminalRenderGridFramesBufferedDuringReplayBySurfaceID.removeValue(forKey: surfaceID) ?? []
        guard hasTerminalOutputSink(surfaceID: surfaceID) else { return }
        if droppedFrames {
            MobileDebugLog.anchormux("sync.render_grid_replay_buffer_tail_flush surface=\(surfaceID) frames=\(frames.count)")
        }
        for frame in frames where replaySeq.map({ frame.stateSeq > $0 }) ?? true {
            deliverAuthoritativeTerminalRenderGrid(frame, expectedSurfaceID: surfaceID, source: "buffered_replay")
        }
    }

    static func terminalSnapshotReplacementBytes(_ snapshotBytes: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        bytes.append(snapshotBytes)
        return bytes
    }

    private func deliverTerminalOutput(_ delivery: TerminalOutputDelivery, surfaceID: String) {
        guard let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              let streamToken = terminalOutputStreamTokensBySurfaceID[surfaceID] else { return }
        var queue = terminalOutputQueuesBySurfaceID[surfaceID] ?? TerminalOutputDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        if let immediate {
            continuation.yield(
                MobileTerminalOutputChunk(data: immediate.bytes, streamToken: streamToken)
            )
        }
    }

    /// Mark the current yielded terminal-output chunk as applied by the iOS surface.
    public func terminalOutputDidProcess(surfaceID: String, streamToken: UUID) {
        guard terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken,
              var queue = terminalOutputQueuesBySurfaceID[surfaceID] else { return }
        let next = queue.completeInFlight()
        terminalOutputQueuesBySurfaceID[surfaceID] = queue
        guard let next,
              let continuation = terminalByteContinuationsBySurfaceID[surfaceID],
              terminalOutputStreamTokensBySurfaceID[surfaceID] == streamToken else {
            return
        }
        continuation.yield(MobileTerminalOutputChunk(data: next.bytes, streamToken: streamToken))
    }

    #if DEBUG
    @discardableResult
    func debugMarkTerminalReplayInFlightForTesting(surfaceID: String) -> UUID {
        let replayID = UUID()
        terminalReplayIDsInFlightBySurfaceID[surfaceID] = replayID
        return replayID
    }

    func debugCancelTerminalReplayForTesting(surfaceID: String) {
        terminalReplayIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridFramesBufferedDuringReplayBySurfaceID.removeValue(forKey: surfaceID)
        terminalRenderGridReplayBufferDroppedSurfaceIDs.remove(surfaceID)
    }

    func debugFinishTerminalReplayForTesting(
        surfaceID: String,
        replayID: UUID? = nil,
        replayFrame: MobileTerminalRenderGridFrame
    ) {
        if let replayID, terminalReplayIDsInFlightBySurfaceID[surfaceID] != replayID {
            return
        }
        terminalReplayIDsInFlightBySurfaceID.removeValue(forKey: surfaceID)
        markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: replayFrame.stateSeq)
        deliverTerminalRenderGrid(replayFrame, surfaceID: surfaceID)
        flushTerminalRenderGridFramesBufferedDuringReplay(
            surfaceID: surfaceID,
            replaySeq: replayFrame.stateSeq
        )
    }
    #endif
}
