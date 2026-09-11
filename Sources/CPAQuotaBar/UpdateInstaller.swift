import CryptoKit
import Foundation

enum UpdateFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(message): return message }
    }
}

/// All file work runs off the UI actor. The old app stays available for rollback.
enum UpdateInstaller {
    static func prepare(archive: URL, digest: String, version: String, target: URL) throws -> URL {
        let manager = FileManager.default
        guard target.pathExtension == "app", manager.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateFailure.message("应用所在文件夹不可写，请先将应用移到“应用程序”文件夹。")
        }
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        let actualDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest.lowercased() == "sha256:" + actualDigest else {
            throw UpdateFailure.message("下载文件校验失败，请重新检查更新。")
        }

        let entries = try run("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n")
        guard !entries.isEmpty, entries.allSatisfy({ entry in
            !entry.hasPrefix("/") && !entry.split(separator: "/").contains("..")
        }) else { throw UpdateFailure.message("更新包包含无效路径。") }

        let extraction = archive.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
        try manager.createDirectory(at: extraction, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: extraction) }
        _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, extraction.path])
        let source = extraction.appendingPathComponent("CPA Quota Bar.app")
        let metadataURL = source.appendingPathComponent("Contents/Info.plist")
        let metadata = try PropertyListSerialization.propertyList(from: Data(contentsOf: metadataURL), format: nil) as? [String: Any]
        guard metadata?["CFBundleIdentifier"] as? String == "me.router-for.cpa-quota-bar",
              metadata?["CFBundleShortVersionString"] as? String == version,
              metadata?["CFBundleExecutable"] as? String == "CPAQuotaBar" else {
            throw UpdateFailure.message("更新包的应用标识或版本不匹配。")
        }
        if let minimum = metadata?["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard current.compare(minimum, options: .numeric) != .orderedAscending else {
                throw UpdateFailure.message("此版本需要 macOS \(minimum) 或更高版本。")
            }
        }
        if let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: [URLResourceKey.isSymbolicLinkKey]) {
            for case let file as URL in enumerator {
                if try file.resourceValues(forKeys: [URLResourceKey.isSymbolicLinkKey]).isSymbolicLink == true {
                    guard file.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/") else {
                        throw UpdateFailure.message("更新包包含指向应用外部的链接。")
                    }
                }
            }
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        let staged = target.deletingLastPathComponent().appendingPathComponent(".CPAQuotaBar-update-\(UUID().uuidString).app")
        do {
            _ = try run("/usr/bin/ditto", [source.path, staged.path])
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            return staged
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    static func replace(staged: URL, target: URL) throws -> URL {
        let manager = FileManager.default
        let backup = target.deletingLastPathComponent().appendingPathComponent(".CPAQuotaBar-backup-\(UUID().uuidString).app")
        try manager.moveItem(at: target, to: backup)
        do {
            try manager.moveItem(at: staged, to: target)
            return backup
        } catch {
            try manager.moveItem(at: backup, to: target)
            throw error
        }
    }

    static func restore(backup: URL, target: URL) throws {
        let failed = target.deletingLastPathComponent().appendingPathComponent(".CPAQuotaBar-failed-\(UUID().uuidString).app")
        try FileManager.default.moveItem(at: target, to: failed)
        do {
            try FileManager.default.moveItem(at: backup, to: target)
            try? FileManager.default.removeItem(at: failed)
        } catch {
            try? FileManager.default.moveItem(at: failed, to: target)
            throw error
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateFailure.message("更新操作失败：\(URL(fileURLWithPath: executable).lastPathComponent)（\(process.terminationStatus)）")
        }
        return String(decoding: output, as: UTF8.self)
    }
}
