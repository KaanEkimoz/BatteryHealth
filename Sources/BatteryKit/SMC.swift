import Foundation
import IOKit

/// Minimal AppleSMC client. Reading most keys works as a normal user;
/// writing requires root.
public enum SMCError: Error, CustomStringConvertible {
    case driverNotFound
    case openFailed(kern_return_t)
    case keyNotFound(String)
    case notPrivileged(String)
    case sizeMismatch(String, expected: Int, got: Int)
    case failure(String, kern_return_t, UInt8)

    public var description: String {
        switch self {
        case .driverNotFound: return "AppleSMC driver not found"
        case .openFailed(let r): return "Could not open AppleSMC (\(String(format: "0x%08x", r)))"
        case .keyNotFound(let k): return "SMC key \(k) not found"
        case .notPrivileged(let k): return "Not privileged to access SMC key \(k) (run as root)"
        case .sizeMismatch(let k, let e, let g): return "SMC key \(k): expected \(e) bytes, got \(g)"
        case .failure(let k, let r, let s): return "SMC key \(k) failed (kr=\(String(format: "0x%08x", r)), smc=\(s))"
        }
    }
}

public struct SMCKeyInfo {
    public let size: Int
    public let type: String
}

/// Layout must match the C struct used by AppleSMC (80 bytes).
private struct SMCParam {
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }

    var key: UInt32 = 0
    var version = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var selector: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum Selector: UInt8 {
    case read = 5, write = 6, keyFromIndex = 8, keyInfo = 9
}

public final class SMC {
    private var connection: io_connect_t = 0
    private var infoCache: [String: SMCKeyInfo] = [:]
    private let lock = NSLock()

    public init() throws {
        precondition(MemoryLayout<SMCParam>.stride == 80, "SMCParam must be 80 bytes")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard r == kIOReturnSuccess else { throw SMCError.openFailed(r) }
    }

    deinit { IOServiceClose(connection) }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func string(_ v: UInt32) -> String {
        let b = [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout SMCParam, key: String) throws -> SMCParam {
        var output = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParam>.stride, &output, &outSize)
        if r == kIOReturnNotPrivileged { throw SMCError.notPrivileged(key) }
        if r == kIOReturnSuccess && output.result == 132 { throw SMCError.keyNotFound(key) }
        guard r == kIOReturnSuccess, output.result == 0 else { throw SMCError.failure(key, r, output.result) }
        return output
    }

    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        lock.lock(); defer { lock.unlock() }
        if let cached = infoCache[key] { return cached }
        var input = SMCParam()
        input.key = Self.fourCC(key)
        input.selector = Selector.keyInfo.rawValue
        let out = try call(&input, key: key)
        let info = SMCKeyInfo(size: Int(out.keyInfo.size), type: Self.string(out.keyInfo.type))
        infoCache[key] = info
        return info
    }

    /// True when the key exists in the SMC key table (it may still be unreadable).
    public func hasKey(_ key: String) -> Bool {
        do { _ = try keyInfo(key); return true }
        catch SMCError.notPrivileged { return true }
        catch { return false }
    }

    public func read(_ key: String) throws -> [UInt8] {
        let info = try keyInfo(key)
        lock.lock(); defer { lock.unlock() }
        var input = SMCParam()
        input.key = Self.fourCC(key)
        input.keyInfo.size = UInt32(info.size)
        input.selector = Selector.read.rawValue
        let out = try call(&input, key: key)
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(min(info.size, 32))) }
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard info.size == bytes.count else { throw SMCError.sizeMismatch(key, expected: info.size, got: bytes.count) }
        lock.lock(); defer { lock.unlock() }
        var input = SMCParam()
        input.key = Self.fourCC(key)
        input.keyInfo.size = UInt32(info.size)
        input.selector = Selector.write.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        _ = try call(&input, key: key)
    }

    public func allKeys() throws -> [String] {
        let countBytes = try read("#KEY")
        let count = countBytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var keys: [String] = []
        for i in 0..<count {
            var input = SMCParam()
            input.selector = Selector.keyFromIndex.rawValue
            input.data32 = i
            lock.lock()
            let out = try? call(&input, key: "#\(i)")
            lock.unlock()
            if let out { keys.append(Self.string(out.key)) }
        }
        return keys
    }
}
