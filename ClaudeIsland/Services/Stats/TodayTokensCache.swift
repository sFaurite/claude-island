//
//  TodayTokensCache.swift
//  ClaudeIsland
//
//  Cache incrémental du compteur « tokens du jour » calculé à partir des JSONL.
//
//  Avant (17/09/2026) : à chaque rafraîchissement des ailes (120 s), StatsReader
//  parcourait ~6 000 répertoires / 25 000 fichiers (≈0,3 s) puis relisait et
//  reparsait intégralement les ~30 Mo de JSONL du jour (≈0,8 s) — 42 % du CPU
//  de l'app. Ici :
//    • le parcours complet n'a lieu qu'au démarrage, au changement de jour UTC,
//      toutes les 30 min par sécurité, ou si FSEvents signale une perte
//      d'événements ; entre-temps, seuls les fichiers signalés modifiés par
//      FSEvents (et ceux déjà connus du jour) sont re-statés ;
//    • chaque fichier n'est reparsé qu'à partir de l'offset déjà traité (les
//      JSONL sont en append seul) ; un fichier inchangé (taille + mtime) n'est
//      pas relu.
//
//  Sémantique alignée sur refresh-claude-stats.mjs : par message.id (ou
//  fichier|timestamp), input/cache comptés une fois et output = valeur finale
//  (max). Depuis le 23/09/2026 : tokens = input + cache_creation + output
//  (intensité, lectures de cache exclues) et coût équivalent API (USD, tarifs
//  ModelPricing, lectures de cache incluses).
//

import Foundation
import os.log

final class TodayTokensCache: @unchecked Sendable {
    static let shared = TodayTokensCache()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "TodayTokensCache")

    /// Parcours complet de secours (rattrape un fichier ancien repris aujourd'hui
    /// sans événement reçu, ou toute désynchronisation).
    private static let fullWalkInterval: TimeInterval = 30 * 60

    struct Usage {
        var model: String
        var input: Int
        var write5m: Int
        var write1h: Int
        var read: Int
        var output: Int
        var webSearches: Int
        var fast: Bool

        var tokens: Int { input + write5m + write1h + output }
        func costUSD(_ pricing: ModelPricing) -> Double {
            pricing.costUSD(model: model, input: input, write5m: write5m, write1h: write1h,
                            read: read, output: output, webSearches: webSearches, fast: fast)
        }
    }

    struct Today: Sendable {
        let tokens: Int
        let costUSD: Double
    }

    private struct FileState {
        var size: UInt64
        var mtime: Date
        /// Octets déjà parsés (toujours juste après un « \n »)
        var parsedOffset: UInt64
        /// Blocs usage du jour trouvés dans ce fichier, par clé de dédup
        var usage: [String: Usage]
    }

    private let lock = NSLock()
    private var dayPrefix = ""
    private var files: [String: FileState] = [:]
    private var dirtyPaths: Set<String> = []
    private var needsFullWalk = true
    private var lastFullWalk: Date?
    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "com.claudeisland.today-tokens-fsevents")

    private static let utcDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Racines scannées : sessions CLI (Mac + miroir VM) et sessions Desktop local-agent-mode.
    static let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/projects"),
            home.appendingPathComponent(".claude-island/projects"),
            home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions"),
        ]
    }()

    private init() {}

    // MARK: - API

    /// Tokens (input + cache_creation + output final) et coût API des blocs usage
    /// datés d'aujourd'hui (UTC). `pricing` : table lue dans stats-cache.json.
    func today(pricing: ModelPricing) -> Today {
        lock.lock(); defer { lock.unlock() }

        startStreamIfNeeded()

        let now = Date()
        let prefix = Self.utcDateFormatter.string(from: now)
        if prefix != dayPrefix {
            dayPrefix = prefix
            files.removeAll()
            dirtyPaths.removeAll()
            needsFullWalk = true
        }

        // Pré-filtre mtime volontairement permissif (minuit local ≤ début du jour
        // UTC en CEST) ; le filtre fin se fait sur le préfixe de timestamp.
        let todayStart = Calendar.current.startOfDay(for: now)

        let candidates: Set<String>
        let fullWalk = needsFullWalk || (lastFullWalk.map { now.timeIntervalSince($0) > Self.fullWalkInterval } ?? true)
        if fullWalk {
            var found = Set<String>()
            for root in Self.roots { Self.walk(root, todayStart: todayStart, into: &found) }
            // Fichiers disparus ou plus « du jour »
            for path in files.keys where !found.contains(path) { files.removeValue(forKey: path) }
            candidates = found
            dirtyPaths.removeAll()
            needsFullWalk = false
            lastFullWalk = now
        } else {
            candidates = Set(files.keys).union(dirtyPaths)
            dirtyPaths.removeAll()
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        var reparsed = 0
        for path in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let mtime = attrs[.modificationDate] as? Date else {
                files.removeValue(forKey: path)
                continue
            }
            guard mtime >= todayStart else {
                files.removeValue(forKey: path)
                continue
            }
            if let cached = files[path], cached.size == size, cached.mtime == mtime {
                continue
            }
            var state: FileState
            if let cached = files[path], size >= cached.size, cached.parsedOffset <= size {
                state = cached   // append seul : on repart de l'offset connu
            } else {
                state = FileState(size: 0, mtime: mtime, parsedOffset: 0, usage: [:])
            }
            Self.parseTail(path: path, from: &state, todayPrefix: prefix)
            state.size = size
            state.mtime = mtime
            files[path] = state
            reparsed += 1
        }

        // Agrégation globale : input une fois, output = max (indépendant de l'ordre)
        var merged: [String: Usage] = [:]
        for state in files.values {
            for (key, u) in state.usage {
                if var m = merged[key] {
                    m.output = max(m.output, u.output)
                    merged[key] = m
                } else {
                    merged[key] = u
                }
            }
        }
        let total = merged.values.reduce(0) { $0 + $1.tokens }
        let cost = merged.values.reduce(0) { $0 + $1.costUSD(pricing) }

        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        Self.logger.debug("todayTokens=\(total) cost=\(cost, format: .fixed(precision: 2)) files=\(self.files.count) reparsed=\(reparsed) fullWalk=\(fullWalk) \(ms, format: .fixed(precision: 1))ms")
        return Today(tokens: total, costUSD: cost)
    }

    // MARK: - Parcours

    private static func walk(_ dir: URL, todayStart: Date, into found: inout Set<String>) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return
        }
        for item in items {
            let rv = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if rv?.isDirectory == true {
                walk(item, todayStart: todayStart, into: &found)
            } else if item.pathExtension == "jsonl", let mtime = rv?.contentModificationDate, mtime >= todayStart {
                found.insert(item.path)
            }
        }
    }

    // MARK: - Parsing incrémental

    /// Parse les lignes complètes ajoutées depuis `state.parsedOffset` et met à jour `state`.
    private static func parseTail(path: String, from state: inout FileState, todayPrefix: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.parsedOffset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }

        // Ne traiter que jusqu'au dernier « \n » : la dernière ligne peut être en cours d'écriture.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]
        state.parsedOffset += UInt64(complete.count)

        let needleAssistant = "\"assistant\"".utf8, needleUsage = "\"usage\"".utf8
        var lineStart = complete.startIndex
        while lineStart < complete.endIndex {
            let lineEnd = complete[lineStart...].firstIndex(of: 0x0A) ?? complete.endIndex
            let line = complete[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            guard !line.isEmpty, contains(line, needleAssistant), contains(line, needleUsage) else { continue }

            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let timestamp = obj["timestamp"] as? String,
                  timestamp.hasPrefix(todayPrefix),
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any] else { continue }

            let key: String
            if let mid = message["id"] as? String {
                key = "msg:\(mid)"
            } else {
                key = "\(path)|\(timestamp)"
            }
            let output = usage["output_tokens"] as? Int ?? 0
            if var existing = state.usage[key] {
                existing.output = max(existing.output, output)
                state.usage[key] = existing
            } else {
                // Répartition des écritures par TTL ; absente → tout en 5 min.
                let created = usage["cache_creation_input_tokens"] as? Int ?? 0
                let byTTL = usage["cache_creation"] as? [String: Any]
                let write1h = byTTL?["ephemeral_1h_input_tokens"] as? Int ?? 0
                let serverTools = usage["server_tool_use"] as? [String: Any]
                state.usage[key] = Usage(
                    model: model,
                    input: usage["input_tokens"] as? Int ?? 0,
                    write5m: max(0, created - write1h),
                    write1h: write1h,
                    read: usage["cache_read_input_tokens"] as? Int ?? 0,
                    output: output,
                    webSearches: serverTools?["web_search_requests"] as? Int ?? 0,
                    fast: usage["speed"] as? String == "fast"
                )
            }
        }
    }

    private static func contains(_ line: Data.SubSequence, _ needle: String.UTF8View) -> Bool {
        let n = Array(needle)
        guard n.count <= line.count else { return false }
        return line.withUnsafeBytes { buf -> Bool in
            let bytes = buf.bindMemory(to: UInt8.self)
            var i = 0
            let last = bytes.count - n.count
            while i <= last {
                if bytes[i] == n[0] {
                    var j = 1
                    while j < n.count && bytes[i + j] == n[j] { j += 1 }
                    if j == n.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    // MARK: - FSEvents

    private func startStreamIfNeeded() {
        guard stream == nil else { return }
        let paths = Self.roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0.path }
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let cache = Unmanaged<TodayTokensCache>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            cache.handleEvents(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else {
            Self.logger.warning("FSEventStreamCreate failed — fallback: full walk at every refresh")
            return
        }
        FSEventStreamSetDispatchQueue(s, eventQueue)
        FSEventStreamStart(s)
        stream = s
    }

    private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        lock.lock(); defer { lock.unlock() }
        let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped
                            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for (path, flag) in zip(paths, flags) {
            if flag & rescan != 0 {
                needsFullWalk = true
            } else if path.hasSuffix(".jsonl") {
                dirtyPaths.insert(path)
            }
        }
    }
}
