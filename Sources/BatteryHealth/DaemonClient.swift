import Foundation
import BatteryKit

/// Talks to the root daemon over its launchd mach service.
final class DaemonClient {
    private var connection: NSXPCConnection?

    private func proxy(onError: @escaping (String) -> Void) -> BatteryDaemonProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: BatteryHealthIDs.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: BatteryDaemonProtocol.self)
            c.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.connection = nil } }
            c.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.connection = nil } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            onError(error.localizedDescription)
        } as? BatteryDaemonProtocol
    }

    func status(_ done: @escaping (Result<DaemonStatus, Error>) -> Void) {
        let once = Once(done)
        guard let p = proxy(onError: { once.call(.failure(NSError(domain: "daemon", code: 1, userInfo: [NSLocalizedDescriptionKey: $0]))) }) else {
            once.call(.failure(NSError(domain: "daemon", code: 2))); return
        }
        p.status { data in
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let data, let s = try? dec.decode(DaemonStatus.self, from: data) { once.call(.success(s)) }
            else { once.call(.failure(NSError(domain: "daemon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bad status payload"]))) }
        }
    }

    func apply(_ config: ChargeConfig, _ done: @escaping (String?) -> Void) {
        let once = Once(done)
        guard let data = try? JSONEncoder().encode(config),
              let p = proxy(onError: { once.call($0) }) else { done("Daemon unavailable"); return }
        p.apply(config: data) { once.call($0) }
    }

    func reset(_ done: @escaping (String?) -> Void) {
        let once = Once(done)
        guard let p = proxy(onError: { once.call($0) }) else { done("Daemon unavailable"); return }
        p.reset { once.call($0) }
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }
}

/// XPC may call either the reply or the error handler; deliver exactly one, on main.
private final class Once<T> {
    private var fn: ((T) -> Void)?
    private let lock = NSLock()
    init(_ fn: @escaping (T) -> Void) { self.fn = fn }
    func call(_ v: T) {
        lock.lock(); let f = fn; fn = nil; lock.unlock()
        if let f { DispatchQueue.main.async { f(v) } }
    }
}
