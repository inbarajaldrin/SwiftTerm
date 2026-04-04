//
//  SyncMetrics.swift
//  SwiftTerm
//
//  Instrumentation for DEC 2026 synchronized output analysis.
//  Tracks draw() calls, queuePendingDisplay() calls, and sync block timing.
//

import Foundation
import os.log

/// Thread-safe metrics singleton for measuring SwiftTerm's rendering behavior
/// during DEC 2026 synchronized output blocks.
///
/// Usage from SwiftTerm internals:
///   SyncMetrics.shared.syncBlockStarted()
///   SyncMetrics.shared.recordDraw()
///
/// Usage from app UI (e.g. overlay):
///   let snap = SyncMetrics.shared.snapshot()
///   print(snap.drawCallsInSync)
public final class SyncMetrics: @unchecked Sendable {
    public static let shared = SyncMetrics()

    // MARK: - Snapshot (read from main thread in overlay timer)

    public struct Snapshot {
        public let drawCallsInSync: Int
        public let drawCallsOutsideSync: Int
        public let queuePendingInSync: Int
        public let queuePendingOutsideSync: Int
        public let syncBlockCount: Int
        public let currentSyncActive: Bool
        public let lastSyncDurationMs: Double
        public let drawsDuringLastSync: Int
        public let queuePendingDuringLastSync: Int
        public let totalDraws: Int
        public let totalQueuePending: Int
        public let syncDelegateCallbacks: Int
    }

    // MARK: - Private state (protected by lock)

    private var lock = os_unfair_lock()
    private let log = OSLog(subsystem: "com.synctermtestbed.metrics", category: "sync")

    private var _drawCallsInSync: Int = 0
    private var _drawCallsOutsideSync: Int = 0
    private var _queuePendingInSync: Int = 0
    private var _queuePendingOutsideSync: Int = 0
    private var _syncBlockCount: Int = 0
    private var _currentSyncActive: Bool = false
    private var _lastSyncDurationMs: Double = 0
    private var _drawsDuringLastSync: Int = 0
    private var _queuePendingDuringLastSync: Int = 0
    private var _totalDraws: Int = 0
    private var _totalQueuePending: Int = 0
    private var _syncDelegateCallbacks: Int = 0

    // Per-sync-block counters (reset on each syncBlockStarted)
    private var _drawsDuringCurrentSync: Int = 0
    private var _queuePendingDuringCurrentSync: Int = 0
    private var _syncStartTime: UInt64 = 0

    private init() {}

    // MARK: - Public API

    /// Call at the top of `beginSynchronizedOutput()`.
    public func syncBlockStarted() {
        os_unfair_lock_lock(&lock)
        _syncBlockCount += 1
        _currentSyncActive = true
        _drawsDuringCurrentSync = 0
        _queuePendingDuringCurrentSync = 0
        _syncStartTime = mach_absolute_time()
        let count = _syncBlockCount
        os_unfair_lock_unlock(&lock)

        os_log(.info, log: log, "SYNC START block=%d", count)
    }

    /// Call inside `endSynchronizedOutput()` after the guard.
    public func syncBlockEnded() {
        os_unfair_lock_lock(&lock)
        let durationMs = machDurationMs(from: _syncStartTime)
        _currentSyncActive = false
        _lastSyncDurationMs = durationMs
        _drawsDuringLastSync = _drawsDuringCurrentSync
        _queuePendingDuringLastSync = _queuePendingDuringCurrentSync
        let count = _syncBlockCount
        let draws = _drawsDuringCurrentSync
        let queues = _queuePendingDuringCurrentSync
        os_unfair_lock_unlock(&lock)

        os_log(.info, log: log, "SYNC END block=%d duration=%.1fms draws=%d queuePending=%d", count, durationMs, draws, queues)
    }

    /// Call inside the timeout closure before `endSynchronizedOutput()`.
    public func syncBlockTimeout() {
        os_unfair_lock_lock(&lock)
        let durationMs = machDurationMs(from: _syncStartTime)
        let count = _syncBlockCount
        let draws = _drawsDuringCurrentSync
        let queues = _queuePendingDuringCurrentSync
        os_unfair_lock_unlock(&lock)

        os_log(.error, log: log, "SYNC TIMEOUT block=%d duration=%.1fms draws=%d queuePending=%d", count, durationMs, draws, queues)
    }

    /// Call at the top of `draw(_ dirtyRect:)`.
    public func recordDraw() {
        os_unfair_lock_lock(&lock)
        _totalDraws += 1
        let syncActive = _currentSyncActive
        if syncActive {
            _drawCallsInSync += 1
            _drawsDuringCurrentSync += 1
        } else {
            _drawCallsOutsideSync += 1
        }
        let total = _totalDraws
        os_unfair_lock_unlock(&lock)

        os_log(.debug, log: log, "DRAW sync=%{bool}d total=%d", syncActive, total)
    }

    /// Call at the top of `queuePendingDisplay()`.
    public func recordQueuePendingDisplay() {
        os_unfair_lock_lock(&lock)
        _totalQueuePending += 1
        let syncActive = _currentSyncActive
        if syncActive {
            _queuePendingInSync += 1
            _queuePendingDuringCurrentSync += 1
        } else {
            _queuePendingOutsideSync += 1
        }
        os_unfair_lock_unlock(&lock)

        os_log(.debug, log: log, "QUEUE_PENDING sync=%{bool}d", syncActive)
    }

    /// Call inside `synchronizedOutputChanged(source:active:)` delegate callback.
    public func recordSyncDelegateCallback(active: Bool) {
        os_unfair_lock_lock(&lock)
        _syncDelegateCallbacks += 1
        os_unfair_lock_unlock(&lock)

        os_log(.info, log: log, "SYNC_DELEGATE active=%{bool}d", active)
    }

    /// Thread-safe snapshot of all current metrics. Call from main thread in overlay timer.
    public func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock)
        let snap = Snapshot(
            drawCallsInSync: _drawCallsInSync,
            drawCallsOutsideSync: _drawCallsOutsideSync,
            queuePendingInSync: _queuePendingInSync,
            queuePendingOutsideSync: _queuePendingOutsideSync,
            syncBlockCount: _syncBlockCount,
            currentSyncActive: _currentSyncActive,
            lastSyncDurationMs: _lastSyncDurationMs,
            drawsDuringLastSync: _drawsDuringLastSync,
            queuePendingDuringLastSync: _queuePendingDuringLastSync,
            totalDraws: _totalDraws,
            totalQueuePending: _totalQueuePending,
            syncDelegateCallbacks: _syncDelegateCallbacks
        )
        os_unfair_lock_unlock(&lock)
        return snap
    }

    /// Zero all counters.
    public func reset() {
        os_unfair_lock_lock(&lock)
        _drawCallsInSync = 0
        _drawCallsOutsideSync = 0
        _queuePendingInSync = 0
        _queuePendingOutsideSync = 0
        _syncBlockCount = 0
        _currentSyncActive = false
        _lastSyncDurationMs = 0
        _drawsDuringLastSync = 0
        _queuePendingDuringLastSync = 0
        _totalDraws = 0
        _totalQueuePending = 0
        _syncDelegateCallbacks = 0
        _drawsDuringCurrentSync = 0
        _queuePendingDuringCurrentSync = 0
        _syncStartTime = 0
        os_unfair_lock_unlock(&lock)

        os_log(.info, log: log, "METRICS RESET")
    }

    // MARK: - Helpers

    /// Convert mach_absolute_time delta to milliseconds.
    private func machDurationMs(from startTime: UInt64) -> Double {
        guard startTime > 0 else { return 0 }
        let elapsed = mach_absolute_time() - startTime
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanos = Double(elapsed) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000.0
    }
}
