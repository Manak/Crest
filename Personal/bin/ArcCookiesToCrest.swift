// Moves cookies from one Chromium-based browser's profile store to another's,
// re-encrypting each value with the destination browser's keychain key. Prints
// counts only; never prints a key, a cookie name or a cookie value.
//
// `arc-cookies-to-crest.py` beside this file builds and drives it.
//
// Usage:
//   ArcCookiesToCrest --source-service "Arc Safe Storage" --source-account Arc \
//     --dest-service "Chromium Safe Storage" --dest-account Chromium \
//     --pair "/path/to/arc/Cookies=/path/to/crest/Cookies" [--pair ...] \
//     [--session-lifetime-days 30] [--only-session-cookies] [--dry-run]
//
// Chromium discards session cookies at launch unless it restores the last
// session, and Crest does not, so `--session-lifetime-days` writes each session
// cookie as a persistent one that expires after that many days.
// `--only-session-cookies` moves nothing else, for a store that already holds
// the persistent cookies.

import CommonCrypto
import Foundation
import SQLite3

struct Fail: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

// MARK: - Keychain and crypto

func keychainPassword(service: String, account: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0,
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !text.isEmpty
    else { throw Fail("Could not read the keychain item \(service) (\(account)).") }
    return text
}

/// Chromium's OSCrypt key on macOS: PBKDF2-SHA1 over the keychain password.
func deriveKey(_ password: String) throws -> [UInt8] {
    var key = [UInt8](repeating: 0, count: 16)
    let salt = Array("saltysalt".utf8)
    let status = password.withCString { pointer in
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), pointer, strlen(pointer), salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    guard status == kCCSuccess else { throw Fail("Key derivation failed (\(status)).") }
    return key
}

func aes(_ operation: CCOperation, key: [UInt8], _ input: [UInt8]) throws -> [UInt8] {
    let iv = [UInt8](repeating: 0x20, count: 16)
    var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
    var moved = 0
    let status = CCCrypt(
        operation, CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
        input, input.count, &output, output.count, &moved)
    guard status == kCCSuccess else { throw Fail("AES failed (\(status)).") }
    return Array(output[0..<moved])
}

func sha256(_ text: String) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let bytes = Array(text.utf8)
    _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
    return digest
}

let versionPrefix = Array("v10".utf8)

/// The cookie's value bytes, from a `v10` record whose plaintext a version 24
/// store prefixes with the SHA-256 of its host key.
func decrypt(_ encrypted: [UInt8], hostKey: String, key: [UInt8]) throws -> (value: [UInt8], hadPrefix: Bool) {
    guard encrypted.count > 3, Array(encrypted[0..<3]) == versionPrefix else { throw Fail("Not a v10 record.") }
    let plain = try aes(CCOperation(kCCDecrypt), key: key, Array(encrypted[3...]))
    let prefix = sha256(hostKey)
    if plain.count >= prefix.count, Array(plain[0..<prefix.count]) == prefix {
        return (Array(plain[prefix.count...]), true)
    }
    return (plain, false)
}

func encrypt(_ value: [UInt8], hostKey: String, key: [UInt8]) throws -> [UInt8] {
    versionPrefix + (try aes(CCOperation(kCCEncrypt), key: key, sha256(hostKey) + value))
}

// MARK: - SQLite

final class Database {
    let handle: OpaquePointer

    init(path: String, readOnly: Bool) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            throw Fail("Could not open \(path).")
        }
        self.handle = opened
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Fail("\(sql): \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw Fail("\(sql): \(String(cString: sqlite3_errmsg(handle)))")
        }
        return prepared
    }

    func scalar(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Fail("\(sql) returned no row.") }
        return sqlite3_column_int64(statement, 0)
    }
}

enum Column {
    case integer(Int64)
    case text(String)
    case blob([UInt8])
    case null
}

func column(_ statement: OpaquePointer, _ index: Int32) -> Column {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT: return .integer(Int64(sqlite3_column_double(statement, index)))
    case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
    case SQLITE_BLOB:
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .blob([]) }
        return .blob(Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: count)))
    default: return .null
    }
}

let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Column) {
    switch value {
    case .integer(let number): sqlite3_bind_int64(statement, index, number)
    case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
    case .blob(let bytes): sqlite3_bind_blob(statement, index, bytes, Int32(bytes.count), transient)
    case .null: sqlite3_bind_null(statement, index)
    }
}

// MARK: - Migration

/// Microseconds since 1601-01-01 UTC, as Chromium stamps cookies.
let chromiumNow = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)

struct Summary {
    var read = 0, expired = 0, skipped = 0, moved = 0, persisted = 0, withoutPrefix = 0, hosts = Set<String>()
}

/// Proves `key` opens `path`'s existing records: every one must decrypt to a
/// plaintext carrying its host key's digest. A store with no records proves
/// nothing and is reported as such.
func verifyKey(path: String, key: [UInt8]) throws -> Int {
    let database = try Database(path: path, readOnly: true)
    let statement = try database.prepare("SELECT host_key, encrypted_value FROM cookies")
    defer { sqlite3_finalize(statement) }
    var checked = 0
    while sqlite3_step(statement) == SQLITE_ROW {
        guard case .text(let host) = column(statement, 0), case .blob(let encrypted) = column(statement, 1) else { continue }
        if encrypted.isEmpty { continue }
        let result = try decrypt(encrypted, hostKey: host, key: key)
        guard result.hadPrefix else { throw Fail("A record in \(path) did not decrypt with the destination key.") }
        checked += 1
    }
    return checked
}

/// Copies every unexpired cookie of `source` into `destination`, replacing a
/// cookie already there with the same identity. A session cookie becomes a
/// persistent one that expires after `sessionLifetime` when that is set, and
/// `onlySession` leaves the persistent cookies behind.
func migrate(
    source: String, destination: String, sourceKey: [UInt8], destinationKey: [UInt8], sessionLifetime: TimeInterval?,
    onlySession: Bool, dryRun: Bool
) throws -> Summary {
    let input = try Database(path: source, readOnly: true)
    let output = try Database(path: destination, readOnly: false)
    let sourceVersion = try input.scalar("SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'version'")
    let destinationVersion = try output.scalar("SELECT CAST(value AS INTEGER) FROM meta WHERE key = 'version'")
    guard sourceVersion == destinationVersion else {
        throw Fail("Store versions differ: source \(sourceVersion), destination \(destinationVersion).")
    }
    guard sourceVersion >= 24 else { throw Fail("Store version \(sourceVersion) is older than this tool handles.") }

    let select = try input.prepare("SELECT * FROM cookies")
    defer { sqlite3_finalize(select) }
    let count = sqlite3_column_count(select)
    let names = (0..<count).map { String(cString: sqlite3_column_name(select, $0)) }
    func index(_ name: String) throws -> Int {
        guard let index = names.firstIndex(of: name) else { throw Fail("Source lacks the \(name) column.") }
        return index
    }
    let hostIndex = try index("host_key"), encryptedIndex = try index("encrypted_value"), valueIndex = try index("value")
    let hasExpiresIndex = try index("has_expires"), expiresIndex = try index("expires_utc")
    let persistentIndex = try index("is_persistent")
    let placeholders = names.map { _ in "?" }.joined(separator: ", ")
    let insert = try output.prepare("INSERT OR REPLACE INTO cookies (\(names.joined(separator: ", "))) VALUES (\(placeholders))")
    defer { sqlite3_finalize(insert) }

    try output.execute("BEGIN IMMEDIATE")
    var summary = Summary()
    while sqlite3_step(select) == SQLITE_ROW {
        summary.read += 1
        var values = (0..<count).map { column(select, $0) }
        guard case .text(let host) = values[hostIndex] else { continue }
        if case .integer(let hasExpires) = values[hasExpiresIndex], hasExpires != 0,
            case .integer(let expires) = values[expiresIndex], expires != 0, expires < chromiumNow {
            summary.expired += 1
            continue
        }
        var isSession = false
        if case .integer(let persistent) = values[persistentIndex], persistent == 0 { isSession = true }
        if onlySession && !isSession {
            summary.skipped += 1
            continue
        }
        if isSession, let lifetime = sessionLifetime {
            values[persistentIndex] = .integer(1)
            values[hasExpiresIndex] = .integer(1)
            values[expiresIndex] = .integer(chromiumNow + Int64(lifetime * 1_000_000))
            summary.persisted += 1
        }
        var plain: [UInt8]
        if case .blob(let encrypted) = values[encryptedIndex], !encrypted.isEmpty {
            let result = try decrypt(encrypted, hostKey: host, key: sourceKey)
            plain = result.value
            if !result.hadPrefix { summary.withoutPrefix += 1 }
        } else if case .text(let clear) = values[valueIndex] {
            plain = Array(clear.utf8)
        } else {
            continue
        }
        values[encryptedIndex] = .blob(try encrypt(plain, hostKey: host, key: destinationKey))
        values[valueIndex] = .text("")
        plain = []
        sqlite3_reset(insert)
        sqlite3_clear_bindings(insert)
        for (offset, value) in values.enumerated() { bind(insert, Int32(offset + 1), value) }
        guard sqlite3_step(insert) == SQLITE_DONE else {
            throw Fail("Insert failed: \(String(cString: sqlite3_errmsg(output.handle)))")
        }
        summary.moved += 1
        summary.hosts.insert(host)
    }
    try output.execute(dryRun ? "ROLLBACK" : "COMMIT")
    return summary
}

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
var sourceService = "", sourceAccount = "", destinationService = "", destinationAccount = ""
var pairs: [(String, String)] = []
var sessionLifetime: TimeInterval?
var onlySessionCookies = false
var dryRun = false
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func next() throws -> String {
        guard !arguments.isEmpty else { throw Fail("\(flag) needs a value.") }
        return arguments.removeFirst()
    }
    do {
        switch flag {
        case "--source-service": sourceService = try next()
        case "--source-account": sourceAccount = try next()
        case "--dest-service": destinationService = try next()
        case "--dest-account": destinationAccount = try next()
        case "--pair":
            let pair = try next()
            guard let separator = pair.firstIndex(of: "=") else { throw Fail("--pair wants source=destination.") }
            pairs.append((String(pair[..<separator]), String(pair[pair.index(after: separator)...])))
        case "--session-lifetime-days":
            guard let days = Double(try next()), days > 0 else { throw Fail("--session-lifetime-days wants a positive number.") }
            sessionLifetime = days * 24 * 60 * 60
        case "--only-session-cookies": onlySessionCookies = true
        case "--dry-run": dryRun = true
        default: throw Fail("Unknown flag \(flag).")
        }
    } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(2)
    }
}

do {
    guard !pairs.isEmpty, !sourceService.isEmpty, !destinationService.isEmpty else { throw Fail("Missing arguments.") }
    print("Reading the source browser's keychain key (\(sourceService))…")
    let sourceKey = try deriveKey(try keychainPassword(service: sourceService, account: sourceAccount))
    print("Reading the destination browser's keychain key (\(destinationService))…")
    let destinationKey = try deriveKey(try keychainPassword(service: destinationService, account: destinationAccount))

    for (_, destination) in pairs {
        let checked = try verifyKey(path: destination, key: destinationKey)
        print("Destination key check for \(destination): \(checked) existing record(s) decrypted correctly.")
    }
    for (source, destination) in pairs {
        let summary = try migrate(
            source: source, destination: destination, sourceKey: sourceKey, destinationKey: destinationKey,
            sessionLifetime: sessionLifetime, onlySession: onlySessionCookies, dryRun: dryRun)
        print(dryRun ? "[dry run] " : "", terminator: "")
        print("\(source) -> \(destination)")
        print("  read \(summary.read), skipped \(summary.expired) expired"
            + (summary.skipped > 0 ? " and \(summary.skipped) persistent" : "")
            + ", moved \(summary.moved) across \(summary.hosts.count) hosts"
            + (summary.persisted > 0 ? ", \(summary.persisted) session cookies made persistent" : "")
            + (summary.withoutPrefix > 0 ? ", \(summary.withoutPrefix) lacked a host digest" : ""))
    }
} catch {
    FileHandle.standardError.write("Failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
