import Foundation
import IOKit
import IOKit.hid

/// Low-level HID transport for a SteelSeries vendor interface.
///
/// This wraps `IOHIDManager` and runs it on a dedicated background thread with
/// its own run loop, so input-report callbacks (used for query responses) are
/// delivered even while the caller is blocked awaiting a reply.
///
/// The SteelSeries Apex Pro TKL Gen 3 exposes its configuration protocol on a
/// vendor-defined HID interface (usage page 0xFFC0, usage 0x0001). Because that
/// is a vendor usage — not a keyboard/mouse usage — macOS does not seize it
/// exclusively, so this transport can open it from a normal user-space process
/// with no kext, entitlement, or root privileges, and it coexists with other
/// clients.
public final class HIDTransport: @unchecked Sendable {

    public struct Match: Sendable {
        public var vendorID: Int
        public var productID: Int
        public var usagePage: Int
        public var usage: Int
        public init(vendorID: Int, productID: Int, usagePage: Int, usage: Int) {
            self.vendorID = vendorID
            self.productID = productID
            self.usagePage = usagePage
            self.usage = usage
        }
    }

    private let manager: IOHIDManager
    private let lock = NSLock()
    private var device: IOHIDDevice?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var started = false

    /// Buffer that receives asynchronous input reports from the device.
    private var inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize: Int

    /// Pending one-shot waiters for the next input report (used for queries),
    /// keyed by token so a timing-out caller only cancels its own waiter.
    private var inputWaiters: [(token: UInt64, deliver: (Result<[UInt8], Error>) -> Void)] = []
    private var nextWaiterToken: UInt64 = 0

    /// Serializes query round-trips so two concurrent queries cannot consume
    /// each other's reply.
    private let queryGate = NSLock()

    /// Called whenever the matched device connects or disconnects. Invoked on
    /// the HID thread.
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    private var connected = false
    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    public init(inputBufferSize: Int = 64) {
        self.manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.inputBufferSize = inputBufferSize
        self.inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        self.inputBuffer.initialize(repeating: 0, count: inputBufferSize)
    }

    deinit {
        stop()
        inputBuffer.deinitialize(count: inputBufferSize)
        inputBuffer.deallocate()
    }

    // MARK: - Lifecycle

    /// Begin matching and open the device if present. Starts a background run
    /// loop. Calling `start` twice is a no-op.
    public func start(match: Match) throws {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()

        let matching: [String: Any] = [
            kIOHIDVendorIDKey: match.vendorID,
            kIOHIDProductIDKey: match.productID,
            kIOHIDDeviceUsagePageKey: match.usagePage,
            kIOHIDDeviceUsageKey: match.usage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue()
            me.deviceAttached(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue()
            me.deviceRemoved(dev)
        }, ctx)

        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { return }
            let rl: CFRunLoop = CFRunLoopGetCurrent()
            self.lock.lock(); self.runLoop = rl; self.lock.unlock()
            IOHIDManagerScheduleWithRunLoop(self.manager, rl, CFRunLoopMode.defaultMode.rawValue)
            _ = IOHIDManagerOpen(self.manager, IOOptionBits(kIOHIDOptionsTypeNone))
            // Pick up any already-connected device. (The matching callback also
            // fires for these once the run loop spins, but doing it eagerly
            // means `isConnected` is true by the time `start` returns.)
            if let set = IOHIDManagerCopyDevices(self.manager) as? Set<IOHIDDevice>, let dev = set.first {
                self.deviceAttached(dev)
            }
            ready.signal()
            // Keep a source alive so CFRunLoopRun does not return immediately
            // if the manager has nothing scheduled yet.
            while !self.shouldStopRunLoop {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
            IOHIDManagerUnscheduleFromRunLoop(self.manager, rl, CFRunLoopMode.defaultMode.rawValue)
        }
        t.name = "io.github.rikearon.apex-control.hid"
        t.stackSize = 512 * 1024
        self.thread = t
        t.start()
        ready.wait()
    }

    private var stopRequested = false
    private var shouldStopRunLoop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    public func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        stopRequested = true
        let rl = runLoop
        runLoop = nil
        started = false
        let waiters = inputWaiters
        inputWaiters.removeAll()
        connected = false
        device = nil
        lock.unlock()

        for w in waiters { w.deliver(.failure(HIDError.deviceDisconnected)) }
        if let rl { CFRunLoopWakeUp(rl) }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: - Attach / detach

    private func deviceAttached(_ dev: IOHIDDevice) {
        lock.lock()
        let already = device != nil
        device = dev
        if !already { connected = true }
        lock.unlock()
        guard !already else { return }

        IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, inputBufferSize, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let me = Unmanaged<HIDTransport>.fromOpaque(ctx).takeUnretainedValue()
            me.handleInputReport(report, length)
        }, ctx)

        onConnectionChange?(true)
    }

    private func deviceRemoved(_ dev: IOHIDDevice) {
        lock.lock()
        guard device === dev else { lock.unlock(); return }
        device = nil
        connected = false
        let waiters = inputWaiters
        inputWaiters.removeAll()
        lock.unlock()

        for w in waiters { w.deliver(.failure(HIDError.deviceDisconnected)) }
        onConnectionChange?(false)
    }

    private func handleInputReport(_ report: UnsafePointer<UInt8>, _ length: CFIndex) {
        let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
        lock.lock()
        let waiters = inputWaiters
        inputWaiters.removeAll()
        lock.unlock()
        for w in waiters { w.deliver(.success(bytes)) }
    }

    // MARK: - Writes

    /// Send a Feature report (control transfer, SET_REPORT). `data` excludes the
    /// report-ID byte; `reportID` (0 for these devices) is supplied separately.
    public func sendFeatureReport(_ data: [UInt8], reportID: Int = 0) throws {
        try send(data, type: kIOHIDReportTypeFeature, reportID: reportID)
    }

    /// Send an Output report (interrupt OUT). `data` excludes the report-ID byte.
    public func sendOutputReport(_ data: [UInt8], reportID: Int = 0) throws {
        try send(data, type: kIOHIDReportTypeOutput, reportID: reportID)
    }

    private func currentDevice() throws -> IOHIDDevice {
        lock.lock(); let dev = device; lock.unlock()
        guard let dev else { throw HIDError.notConnected }
        return dev
    }

    private func send(_ data: [UInt8], type: IOHIDReportType, reportID: Int) throws {
        let dev = try currentDevice()
        let result = data.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(dev, type, CFIndex(reportID), buf.baseAddress!, buf.count)
        }
        guard result == kIOReturnSuccess else { throw HIDError.ioReturn(result) }
    }

    // MARK: - Feature reads

    /// Read a Feature report (control transfer, GET_REPORT) of `length` bytes.
    /// The returned array excludes the report-ID byte.
    public func getFeatureReport(length: Int, reportID: Int = 0) throws -> [UInt8] {
        let dev = try currentDevice()
        var buffer = [UInt8](repeating: 0, count: length)
        var reported = CFIndex(length)
        let result = buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(reportID), buf.baseAddress!, &reported)
        }
        guard result == kIOReturnSuccess else { throw HIDError.ioReturn(result) }
        return Array(buffer.prefix(max(0, min(length, Int(reported)))))
    }

    /// Write a Feature request then read the Feature reply — the
    /// request-and-reply pattern used for bulk read-back (button mappings, macro
    /// data, onboard profiles).
    /// - Parameter settleTime: pause between the write and the read. Some
    ///   replies are not ready on an immediate GET.
    public func queryFeature(_ request: [UInt8], responseLength: Int, reportID: Int = 0,
                             settleTime: TimeInterval = 0) throws -> [UInt8] {
        queryGate.lock(); defer { queryGate.unlock() }
        try sendFeatureReport(request, reportID: reportID)
        if settleTime > 0 { Thread.sleep(forTimeInterval: settleTime) }
        return try getFeatureReport(length: responseLength, reportID: reportID)
    }

    // MARK: - Query (write Output, then await Input report)

    /// Send an Output report and wait for the next Input report, with a timeout.
    /// Used for read-back queries (firmware version, region, layout).
    public func query(_ request: [UInt8], reportID: Int = 0, timeout: TimeInterval = 1.0) throws -> [UInt8] {
        queryGate.lock(); defer { queryGate.unlock() }

        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()

        lock.lock()
        nextWaiterToken &+= 1
        let token = nextWaiterToken
        inputWaiters.append((token: token, deliver: { r in
            box.set(r)
            sem.signal()
        }))
        lock.unlock()

        do {
            try sendOutputReport(request, reportID: reportID)
        } catch {
            cancelWaiter(token)
            throw error
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            cancelWaiter(token)
            throw HIDError.timeout
        }
        return try box.get()
    }

    private func cancelWaiter(_ token: UInt64) {
        lock.lock()
        inputWaiters.removeAll { $0.token == token }
        lock.unlock()
    }

    /// Small box so the semaphore hand-off has a single writer/reader.
    private final class ResultBox: @unchecked Sendable {
        private let l = NSLock()
        private var value: Result<[UInt8], Error> = .failure(HIDError.timeout)
        func set(_ r: Result<[UInt8], Error>) { l.lock(); value = r; l.unlock() }
        func get() throws -> [UInt8] { l.lock(); defer { l.unlock() }; return try value.get() }
    }
}

public enum HIDError: Error, CustomStringConvertible, Sendable {
    case notConnected
    case deviceDisconnected
    case timeout
    case malformedReply
    case ioReturn(IOReturn)

    public var description: String {
        switch self {
        case .notConnected: return "No SteelSeries device connected"
        case .deviceDisconnected: return "Device disconnected"
        case .timeout: return "Timed out waiting for device response"
        case .malformedReply: return "The keyboard returned an unexpected reply"
        case .ioReturn(let r): return String(format: "IOHID error 0x%08X", UInt32(bitPattern: r))
        }
    }
}

extension HIDError: LocalizedError {
    public var errorDescription: String? { description }
}
