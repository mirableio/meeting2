import Foundation
import TPCircularBuffer

final class CircularAudioBuffer {
    // Thin Swift owner of a TPCircularBuffer: a fixed-size queue that one thread writes
    // and one thread reads (single-producer, single-consumer) without locking. Here the
    // writer is Core Audio's real-time callback and the reader is TrackWriter. We use an
    // established, audited ring rather than rolling our own, because getting lock-free
    // memory ordering subtly wrong is exactly the kind of rare bug that loses meetings.
    private let storage: UnsafeMutablePointer<TPCircularBuffer>

    init(byteCapacity: Int) throws {
        storage = UnsafeMutablePointer<TPCircularBuffer>.allocate(capacity: 1)
        storage.initialize(to: TPCircularBuffer())

        guard _TPCircularBufferInit(storage, UInt32(byteCapacity), MemoryLayout<TPCircularBuffer>.size) else {
            storage.deinitialize(count: 1)
            storage.deallocate()
            throw CaptureError.invalidState("Could not initialize circular audio buffer")
        }
    }

    deinit {
        TPCircularBufferCleanup(storage)
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func produce(_ source: UnsafeRawPointer, byteCount: Int) -> Bool {
        TPCircularBufferProduceBytes(storage, source, UInt32(byteCount))
    }

    var realtimeStorage: UnsafeMutablePointer<TPCircularBuffer> {
        // The system tap's C IOProc needs the C ring pointer directly so it can
        // avoid Swift method dispatch and ARC traffic on Core Audio's realtime
        // thread. Keep ownership here; callers may borrow, never free.
        storage
    }

    func tail(availableBytes: inout UInt32) -> UnsafeMutableRawPointer? {
        TPCircularBufferTail(storage, &availableBytes)
    }

    func consume(byteCount: Int) {
        TPCircularBufferConsume(storage, UInt32(byteCount))
    }
}
