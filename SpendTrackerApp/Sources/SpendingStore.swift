import Combine
import Foundation

struct KeyEntry: Identifiable {
    let id: String           // fingerprint
    let tail: String         // last 4 chars of the key
    let provider: String
    let usd: Double
}

struct DriftEntry: Identifiable {
    let id: String           // provider name doubles as id
    let provider: String
    let state: String        // "OK" or "DRIFT"
    let proxyUSD: Double
    let vendorUSD: Double
    let deltaPct: Double
}

struct VendorTruth {
    let provider: String
    let usd: Double
    let fetchedAt: Date?
    let covers: String       // e.g. "yesterday_utc"
}

struct SpendingState {
    var totalUSD: Double = 0
    var byProvider: [(provider: String, usd: Double)] = []
    var byModel: [(model: String, usd: Double)] = []
    var byKey: [KeyEntry] = []
    var drift: [DriftEntry] = []
    var anyDrift: Bool = false
    var vendorTruthByProvider: [String: VendorTruth] = [:]

    func vendorTruth(for provider: String) -> VendorTruth? {
        vendorTruthByProvider[provider]
    }
    var date: String = ""
    var lastUpdated: Date? = nil
    var lastReconciled: Date? = nil
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0
}

@MainActor
final class SpendingStore: ObservableObject {
    @Published var state = SpendingState()
    @Published var proxyRunning = false
    @Published var isStale = false

    private let stateURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".ai-spending/state.json")
    private var timer: Timer?
    private var lastModified: Date? = nil

    init() {
        reload()
        checkProxy()
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                self?.checkProxy()
            }
        }
    }

    func reload() {
        guard let data = try? Data(contentsOf: stateURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            isStale = true
            return
        }

        var s = SpendingState()
        s.totalUSD = (json["total_usd"] as? Double) ?? 0
        s.date = (json["date"] as? String) ?? ""
        s.cacheCreationTokens = (json["cache_creation_tokens"] as? Int) ?? 0
        s.cacheReadTokens = (json["cache_read_tokens"] as? Int) ?? 0

        if let ts = json["last_updated"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            s.lastUpdated = fmt.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        }

        if let bp = json["by_provider"] as? [String: Double] {
            s.byProvider = bp.sorted { $0.value > $1.value }.map { (provider: $0.key, usd: $0.value) }
        }
        if let bm = json["by_model"] as? [String: Double] {
            s.byModel = bm.sorted { $0.value > $1.value }.map { (model: $0.key, usd: $0.value) }
        }
        if let bk = json["by_key"] as? [String: [String: Any]] {
            s.byKey = bk.compactMap { (fp, info) -> KeyEntry? in
                guard let usd = info["usd"] as? Double else { return nil }
                let tail = (info["tail"] as? String) ?? ""
                let provider = (info["provider"] as? String) ?? ""
                return KeyEntry(id: fp, tail: tail, provider: provider, usd: usd)
            }
            .sorted { $0.usd > $1.usd }
        }
        if let vt = json["vendor_truth"] as? [String: [String: Any]] {
            var map: [String: VendorTruth] = [:]
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for (provider, info) in vt {
                let usd = (info["usd"] as? Double) ?? 0
                let covers = (info["covers"] as? String) ?? ""
                var fetched: Date? = nil
                if let ts = info["fetched_at"] as? String {
                    fetched = fmt.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
                }
                map[provider] = VendorTruth(provider: provider, usd: usd, fetchedAt: fetched, covers: covers)
            }
            s.vendorTruthByProvider = map
        }
        if let drift = json["drift"] as? [String: [String: Any]] {
            s.drift = drift.compactMap { (provider, info) -> DriftEntry? in
                let state = (info["state"] as? String) ?? "OK"
                let proxy = (info["last_proxy_usd"] as? Double) ?? 0
                let vendor = (info["last_vendor_usd"] as? Double) ?? 0
                let delta = (info["delta_pct"] as? Double) ?? 0
                return DriftEntry(id: provider, provider: provider, state: state,
                                  proxyUSD: proxy, vendorUSD: vendor, deltaPct: delta)
            }
            .sorted { $0.provider < $1.provider }
            s.anyDrift = s.drift.contains { $0.state == "DRIFT" }
        }
        if let ts = json["last_reconciled"] as? String {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            s.lastReconciled = fmt.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
        }

        state = s

        let todayISO: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f.string(from: Date())
        }()
        let dateMismatch = !s.date.isEmpty && s.date != todayISO
        let ageStale: Bool = {
            guard let ts = s.lastUpdated else { return true }
            return Date().timeIntervalSince(ts) > 30 * 60
        }()
        isStale = dateMismatch || ageStale
    }

    func checkProxy() {
        let pidURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ai-spending/proxy.pid")
        guard let pidStr = try? String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr)
        else {
            proxyRunning = false
            return
        }
        proxyRunning = kill(pid, 0) == 0
    }

    func resetState() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", """
import sys, json, os, tempfile
from pathlib import Path
from datetime import date, datetime, timezone
state_dir = Path.home() / ".ai-spending"
state_file = state_dir / "state.json"
state = {"date": date.today().isoformat(), "total_usd": 0.0, "by_provider": {}, "by_model": {}, "cache_creation_tokens": 0, "cache_read_tokens": 0, "last_updated": datetime.now(timezone.utc).isoformat()}
tmp = tempfile.NamedTemporaryFile(mode="w", dir=state_dir, delete=False, suffix=".tmp")
json.dump(state, tmp, indent=2)
tmp.flush()
os.fsync(tmp.fileno())
tmp.close()
os.replace(tmp.name, state_file)
"""]
        try? task.run()
        task.waitUntilExit()
        reload()
    }

    func startProxy() {
        let script = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("proxy/server.py")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script.path]
        try? task.run()
    }
}
