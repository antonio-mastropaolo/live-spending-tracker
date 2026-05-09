import Combine
import Foundation

// MARK: - v2 model types
//
// The store decodes ~/.ai-spending/state.json (schema_version 2). It also
// tolerates v1-only files written by older proxies that haven't picked up
// the v2 helpers — those appear as empty `accounts` and the UI falls back
// to v1 fields (proxy total / by_provider / by_key) automatically.

struct WorkspaceEntry: Identifiable, Hashable {
    let id: String           // workspace_id (Anthropic) or project_id (OpenAI)
    let label: String
    let usd: Double
}

struct AccountKeyEntry: Identifiable, Hashable {
    let id: String           // api_key_id (vendor-canonical)
    let label: String
    let tail: String
    let usd: Double
}

struct AccountYesterday {
    let date: String
    let usd: Double
    let workspaces: [WorkspaceEntry]
    let keys: [AccountKeyEntry]
}

struct AccountBudgets: Hashable {
    let dailyUSD: Double?
    let monthlyUSD: Double?

    var isSet: Bool { dailyUSD != nil || monthlyUSD != nil }
}

struct AccountState: Identifiable, Hashable {
    let id: String           // operator-chosen registry id
    let label: String
    let provider: String
    let yesterday: AccountYesterday
    let trend7d: [Double]
    var error: AccountError? = nil
    var budgets: AccountBudgets = AccountBudgets(dailyUSD: nil, monthlyUSD: nil)

    static func == (lhs: AccountState, rhs: AccountState) -> Bool { lhs.id == rhs.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct AccountError: Hashable {
    let kind: String         // "auth" | "network" | "http" | "parse" | "internal"
    let message: String
    let at: Date?
}

struct TodayEstimate: Hashable {
    let usd: Double
    let lastUpdated: Date?
    let burnRateCentsPerMin: Double  // 0 when idle; > 0 while proxy is hot
}

// MARK: - Legacy v1 carriers (still surfaced when accounts is empty)

struct KeyEntry: Identifiable {
    let id: String           // fingerprint
    let tail: String
    let provider: String
    let usd: Double
}

struct DriftEntry: Identifiable {
    let id: String
    let provider: String
    let state: String
    let proxyUSD: Double
    let vendorUSD: Double
    let deltaPct: Double
}

struct VendorTruth {
    let provider: String
    let usd: Double
    let fetchedAt: Date?
    let covers: String
}

// MARK: - SpendingState

struct SpendingState {
    // v2 fields (primary source of truth when accounts is non-empty).
    var accounts: [AccountState] = []
    var totalsYesterdayUSD: Double = 0
    var todayEstimate: TodayEstimate? = nil
    var errorsByAccount: [String: AccountError] = [:]

    // v1 fields (kept around for the additive period and proxy ghost row).
    var totalUSD: Double = 0           // proxy intra-day total ("today on this laptop")
    var byProvider: [(provider: String, usd: Double)] = []
    var byModel: [(model: String, usd: Double)] = []
    var byKey: [KeyEntry] = []
    var drift: [DriftEntry] = []
    var anyDrift: Bool = false
    var vendorTruthByProvider: [String: VendorTruth] = [:]

    func vendorTruth(for provider: String) -> VendorTruth? { vendorTruthByProvider[provider] }
    var date: String = ""
    var lastUpdated: Date? = nil
    var lastReconciled: Date? = nil
    var cacheCreationTokens: Int = 0
    var cacheReadTokens: Int = 0

    /// True when the v2 registry path is populated — the UI uses this to
    /// pick between the multi-account overview and the legacy provider list.
    var hasV2Accounts: Bool { !accounts.isEmpty }

    /// Headline number shown in the menu bar icon.
    /// v2: totals.yesterday_usd + (today_estimate.usd ?? 0)
    /// v1: legacy proxy total
    var headlineUSD: Double {
        if hasV2Accounts {
            return totalsYesterdayUSD + (todayEstimate?.usd ?? 0)
        }
        return totalUSD
    }
}

// MARK: - Navigation

enum NavTier: Equatable {
    case overview
    case account(id: String)
    case key(accountID: String, keyID: String)
    case history
}

// MARK: - SpendingStore

@MainActor
final class SpendingStore: ObservableObject {
    @Published var state = SpendingState()
    @Published var proxyRunning = false
    @Published var isStale = false
    @Published var nav: NavTier = .overview
    /// {account_id: {date_iso: usd}}. Loaded lazily and refreshed on each
    /// reload tick. Empty when ~/.ai-spending/history.json doesn't exist
    /// (v1-fallback or first-poll-not-yet-fired).
    @Published var history: [String: [String: Double]] = [:]

    private let stateURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".ai-spending/state.json")
    private let historyURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".ai-spending/history.json")
    private var timer: Timer?

    init() {
        reload()
        checkProxy()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                self?.checkProxy()
            }
        }
    }

    /// Re-read ~/.ai-spending/history.json. Cheap (≤ 1 KB per account at
    /// 90 days). Called from reload() so heatmap + forecast + WoW always
    /// reflect what the reconciler last wrote.
    private func reloadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            history = [:]
            return
        }
        var out: [String: [String: Double]] = [:]
        for (aid, days) in json {
            guard let dayMap = days as? [String: Any] else { continue }
            var clean: [String: Double] = [:]
            for (d, v) in dayMap {
                if let usd = v as? Double { clean[d] = usd }
                else if let n = v as? NSNumber { clean[d] = n.doubleValue }
            }
            out[aid] = clean
        }
        history = out
    }

    func reload() {
        reloadHistory()

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

        let isoFmt: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let isoFmtPlain = ISO8601DateFormatter()

        func parseISO(_ raw: Any?) -> Date? {
            guard let s = raw as? String else { return nil }
            return isoFmt.date(from: s) ?? isoFmtPlain.date(from: s)
        }

        s.lastUpdated = parseISO(json["last_updated"])
        s.lastReconciled = parseISO(json["last_reconciled"])

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
            for (provider, info) in vt {
                let usd = (info["usd"] as? Double) ?? 0
                let covers = (info["covers"] as? String) ?? ""
                map[provider] = VendorTruth(
                    provider: provider, usd: usd,
                    fetchedAt: parseISO(info["fetched_at"]), covers: covers
                )
            }
            s.vendorTruthByProvider = map
        }
        if let drift = json["drift"] as? [String: [String: Any]] {
            s.drift = drift.compactMap { (provider, info) -> DriftEntry? in
                let st = (info["state"] as? String) ?? "OK"
                let proxy = (info["last_proxy_usd"] as? Double) ?? 0
                let vendor = (info["last_vendor_usd"] as? Double) ?? 0
                let delta = (info["delta_pct"] as? Double) ?? 0
                return DriftEntry(id: provider, provider: provider, state: st,
                                  proxyUSD: proxy, vendorUSD: vendor, deltaPct: delta)
            }
            .sorted { $0.provider < $1.provider }
            s.anyDrift = s.drift.contains { $0.state == "DRIFT" }
        }

        // ---- v2 fields ----

        // errors[]: index by account_id, latest wins.
        var errorsByAccount: [String: AccountError] = [:]
        if let errs = json["errors"] as? [[String: Any]] {
            for e in errs {
                guard let aid = e["account_id"] as? String else { continue }
                let kind = (e["kind"] as? String) ?? "internal"
                let msg = (e["msg"] as? String) ?? ""
                let at = parseISO(e["at"])
                errorsByAccount[aid] = AccountError(kind: kind, message: msg, at: at)
            }
        }
        s.errorsByAccount = errorsByAccount

        if let totals = json["totals"] as? [String: Any] {
            s.totalsYesterdayUSD = (totals["yesterday_usd"] as? Double) ?? 0
        }

        if let te = json["today_estimate"] as? [String: Any] {
            let usd = (te["usd"] as? Double) ?? 0
            let burn = (te["burn_rate_cents_per_min"] as? Double) ?? 0
            s.todayEstimate = TodayEstimate(
                usd: usd,
                lastUpdated: parseISO(te["last_updated"]),
                burnRateCentsPerMin: burn
            )
        }

        if let accts = json["accounts"] as? [String: [String: Any]] {
            s.accounts = accts.compactMap { (id, info) -> AccountState? in
                let label = (info["label"] as? String) ?? id
                let provider = (info["provider"] as? String) ?? ""
                let yest = info["yesterday"] as? [String: Any] ?? [:]
                let yDate = (yest["date"] as? String) ?? ""
                let yUSD = (yest["usd"] as? Double) ?? 0
                let workspaces: [WorkspaceEntry] = {
                    guard let bw = yest["by_workspace"] as? [String: [String: Any]] else { return [] }
                    return bw.compactMap { (wid, w) -> WorkspaceEntry? in
                        guard let usd = w["usd"] as? Double else { return nil }
                        let label = (w["label"] as? String) ?? wid
                        return WorkspaceEntry(id: wid, label: label.isEmpty ? wid : label, usd: usd)
                    }
                    .sorted { $0.usd > $1.usd }
                }()
                let keys: [AccountKeyEntry] = {
                    guard let bk = yest["by_key"] as? [String: [String: Any]] else { return [] }
                    return bk.compactMap { (kid, k) -> AccountKeyEntry? in
                        guard let usd = k["usd"] as? Double else { return nil }
                        let label = (k["label"] as? String) ?? ""
                        let tail = (k["tail"] as? String) ?? ""
                        return AccountKeyEntry(id: kid, label: label, tail: tail, usd: usd)
                    }
                    .sorted { $0.usd > $1.usd }
                }()
                let trend = (info["trend_7d_usd"] as? [Double]) ?? []
                let budgets: AccountBudgets = {
                    guard let b = info["budgets"] as? [String: Any] else {
                        return AccountBudgets(dailyUSD: nil, monthlyUSD: nil)
                    }
                    return AccountBudgets(
                        dailyUSD: b["daily_usd"] as? Double,
                        monthlyUSD: b["monthly_usd"] as? Double
                    )
                }()
                return AccountState(
                    id: id,
                    label: label,
                    provider: provider,
                    yesterday: AccountYesterday(date: yDate, usd: yUSD, workspaces: workspaces, keys: keys),
                    trend7d: trend,
                    error: errorsByAccount[id],
                    budgets: budgets
                )
            }
            .sorted { $0.yesterday.usd > $1.yesterday.usd }
        }

        // Drop any nav target whose account/key no longer exists — keeps
        // the popover from being stuck on a deleted entry.
        switch nav {
        case .overview, .history:
            break
        case .account(let id):
            if !s.accounts.contains(where: { $0.id == id }) { nav = .overview }
        case .key(let aid, let kid):
            let acct = s.accounts.first(where: { $0.id == aid })
            if acct == nil || !(acct?.yesterday.keys.contains(where: { $0.id == kid }) ?? false) {
                nav = .overview
            }
        }

        state = s

        // Staleness: in v2 mode, the registry reconciler stamps
        // last_reconciled — that's the freshest live signal. If older than
        // 30 minutes, dim. In v1-only mode keep the legacy date+lastUpdated
        // logic so older proxies don't always look stale.
        let todayISO: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f.string(from: Date())
        }()
        if s.hasV2Accounts {
            if let lr = s.lastReconciled {
                isStale = Date().timeIntervalSince(lr) > 30 * 60
            } else {
                isStale = true
            }
        } else {
            let dateMismatch = !s.date.isEmpty && s.date != todayISO
            let ageStale: Bool = {
                guard let ts = s.lastUpdated else { return true }
                return Date().timeIntervalSince(ts) > 30 * 60
            }()
            isStale = dateMismatch || ageStale
        }
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

    // MARK: - Nav helpers
    func showAccount(_ id: String) { nav = .account(id: id) }
    func showKey(_ accountID: String, _ keyID: String) { nav = .key(accountID: accountID, keyID: keyID) }
    func showHistory() { nav = .history }
    func popToOverview() { nav = .overview }
    func popToAccount() {
        if case .key(let aid, _) = nav { nav = .account(id: aid) } else { nav = .overview }
    }

    func account(id: String) -> AccountState? { state.accounts.first(where: { $0.id == id }) }

    // MARK: - Derived analytics (history-backed)

    private static let isoDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Today's spend for one account (reading history.json — vendor-truth
    /// once reconciled, otherwise empty). Month-to-date for forecast.
    func todaySpend(for accountID: String) -> Double {
        guard let bucket = history[accountID] else { return 0 }
        let today = Self.isoDayFmt.string(from: Date())
        return bucket[today] ?? 0
    }

    func monthToDateSpend(for accountID: String) -> Double {
        guard let bucket = history[accountID] else { return 0 }
        let prefix = String(Self.isoDayFmt.string(from: Date()).prefix(7)) + "-"
        return bucket
            .filter { $0.key.hasPrefix(prefix) }
            .values
            .reduce(0, +)
    }

    /// Linear projection: MTD ÷ days-elapsed × days-in-month. Returns nil
    /// when there isn't enough data to project meaningfully.
    func forecastEndOfMonth(for accountID: String) -> Double? {
        let mtd = monthToDateSpend(for: accountID)
        guard mtd > 0 else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let day = cal.component(.day, from: now)
        guard let range = cal.range(of: .day, in: .month, for: now) else { return nil }
        let daysInMonth = range.count
        return mtd / Double(day) * Double(daysInMonth)
    }

    /// (this 7d / prior 7d − 1). Nil when prior 7d is zero (no
    /// denominator → no meaningful percentage).
    func weekOverWeek(for accountID: String) -> Double? {
        guard let bucket = history[accountID], bucket.count >= 8 else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        var thisWeek = 0.0
        var lastWeek = 0.0
        for offset in 1...14 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.isoDayFmt.string(from: d)
            if let v = bucket[key] {
                if offset <= 7 { thisWeek += v } else { lastWeek += v }
            }
        }
        guard lastWeek > 0 else { return nil }
        return thisWeek / lastWeek - 1.0
    }

    /// Aggregate forecast across all accounts (sum of per-account
    /// forecasts). Nil when none have data.
    var forecastTotalEndOfMonth: Double? {
        let parts = state.accounts.compactMap { forecastEndOfMonth(for: $0.id) }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// {date_iso → total_usd} across all accounts, last 90 days. Used by
    /// the History tier heatmap. Stable order isn't required — the view
    /// indexes by date.
    func dailyTotalsAcrossAccounts() -> [String: Double] {
        var out: [String: Double] = [:]
        for (_, days) in history {
            for (d, v) in days {
                out[d, default: 0] += v
            }
        }
        return out
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
# Preserve v2 fields (accounts/totals/errors) — reset only zeros the proxy
# intra-day totals. Vendor-truth lives on its own daily cycle.
existing = {}
try:
    existing = json.loads(state_file.read_text())
except Exception:
    pass
keep_keys = ("schema_version", "accounts", "totals", "errors", "today_estimate", "last_reconciled")
preserved = {k: existing.get(k) for k in keep_keys if k in existing}
state = {
    "date": date.today().isoformat(),
    "total_usd": 0.0, "by_provider": {}, "by_model": {}, "by_key": {},
    "cache_creation_tokens": 0, "cache_read_tokens": 0,
    "last_updated": datetime.now(timezone.utc).isoformat(),
}
state.update({k: v for k, v in preserved.items() if v is not None})
state.setdefault("schema_version", 2)
tmp = tempfile.NamedTemporaryFile(mode="w", dir=state_dir, delete=False, suffix=".tmp")
json.dump(state, tmp, indent=2)
tmp.flush(); os.fsync(tmp.fileno()); tmp.close()
os.replace(tmp.name, state_file)
"""]
        try? task.run()
        task.waitUntilExit()
        reload()
    }

    /// Flip the `enabled` flag on a registry entry by shelling out to the
    /// CLI. After success, force a reload so the popover updates and the
    /// Account Detail tier pops back to Overview if the account is now
    /// hidden. The reconciler's next tick (≤5 min) finalizes the removal
    /// from state.json; this just kicks the UI immediately.
    func setAccountEnabled(_ accountID: String, enabled: Bool) {
        let action = enabled ? "enable" : "disable"
        let projectRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-m", "registry", action, accountID]
        task.environment = ProcessInfo.processInfo.environment
        var env = task.environment ?? [:]
        env["PYTHONPATH"] = projectRoot
        task.environment = env
        task.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        try? task.run()
        task.waitUntilExit()

        // Pop nav back so the user isn't stuck on a now-hidden detail page.
        if !enabled, case .account(let aid) = nav, aid == accountID {
            popToOverview()
        }
        if !enabled, case .key(let aid, _) = nav, aid == accountID {
            popToOverview()
        }
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
