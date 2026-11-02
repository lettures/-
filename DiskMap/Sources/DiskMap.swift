import SwiftUI
import AppKit
import Darwin
import CryptoKit

enum FileKind: String, CaseIterable, Identifiable, Sendable {
    case all = "全部", video = "视频", image = "图片", document = "文档", archive = "压缩包", application = "应用", audio = "音频", other = "其他"
    var id: String { rawValue }
    static func classify(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["app", "framework", "bundle", "plugin"].contains(ext) { return .application }
        if ["mp4", "mov", "mkv", "avi", "m4v", "webm"].contains(ext) { return .video }
        if ["jpg", "jpeg", "png", "heic", "gif", "tiff", "webp", "raw", "svg"].contains(ext) { return .image }
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "pages", "numbers", "key", "epub"].contains(ext) { return .document }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "pkg"].contains(ext) { return .archive }
        if ["mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff"].contains(ext) { return .audio }
        return .other
    }
}
// One directory URL shared by all its children; file nodes retain only a basename.
final class DirectoryLocation: @unchecked Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
}
// Mutable only on the scanner worker. Published snapshots are deep copies; final trees are frozen.
final class Node: Identifiable, @unchecked Sendable {
    let location: DirectoryLocation
    let directory: Bool, kind: FileKind, synthetic: Bool
    var url: URL { location.url.appendingPathComponent(basename, isDirectory: directory) }
    let basename: String
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var name: String { label ?? basename }
    var label: String?
    var children: ArraySlice<Node> = []
    var preview: [Node] = []
    weak var parent: Node?
    var source: Node?
    var scannedIdentity: ScanIdentity?
    var diskBytes: Int64?
    var footprint: Int64 { diskBytes ?? bytes }
    var bytes: Int64 = 0
    convenience init(_ url: URL, _ directory: Bool, kind: FileKind? = nil, synthetic: Bool = false) {
        self.init(name: url.lastPathComponent, location: DirectoryLocation(url.deletingLastPathComponent()), directory: directory, kind: kind ?? FileKind.classify(url), synthetic: synthetic)
    }
    init(name: String, location: DirectoryLocation, directory: Bool, kind: FileKind, synthetic: Bool = false) {
        self.location = location; self.basename = name; self.directory = directory; self.kind = kind; self.synthetic = synthetic
    }
}
struct ScanResult: @unchecked Sendable { let root: Node; let errors: [String]; var count = 0 }
struct ScanProgress: @unchecked Sendable { let root: Node; let errors: [String]; let count: Int }
enum Scanner {
    static func message(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError { return "无权限读取，请检查文件夹权限或系统隐私设置。" }
        if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { return "文件已移动或不存在。" }
        return "无法读取：" + error.localizedDescription
    }
    static func scan(_ url: URL, progress: ((ScanProgress) -> Void)? = nil) throws -> ScanResult {
        var errors: [String] = [], stack: [Node] = [], count = 0
        var last = Date.distantPast
        let root = Node(url, true); root.diskBytes = 0
        func report(_ path: URL, _ error: Error) { if errors.count < 500 { errors.append("\(path.path)：\(message(error))") } }
        var snapshotBudget = 1500
        func snapshot(_ n: Node, _ depth: Int) -> Node {
            snapshotBudget -= 1
            let copy = Node(n.url, n.directory, kind: n.kind); copy.bytes = n.bytes; copy.diskBytes = n.diskBytes
            if depth < 4 && snapshotBudget > 0 {
                var candidates = n.preview
                if let index = stack.firstIndex(where: { $0 === n }), index + 1 < stack.count {
                    let active = stack[index + 1]
                    if !candidates.contains(where: { $0 === active }) { candidates.append(active) }
                }
                copy.children = ArraySlice(candidates.sorted { $0.bytes > $1.bytes }.map { snapshot($0, depth + 1) })
                let omitted = max(0, n.bytes - copy.children.reduce(0) { $0 + $1.bytes })
                if omitted > 0 || n.footprint > copy.children.reduce(0, { $0 + $1.footprint }) { let rest = Node(n.url, false, synthetic: true); rest.label = "其余已扫描项目"; rest.bytes = omitted; rest.diskBytes = max(0, n.footprint - copy.children.reduce(0) { $0 + $1.footprint }); copy.children.append(rest) }
                copy.children.sort { $0.bytes > $1.bytes }
                for child in copy.children where child.directory { child.parent = copy }
            }
            return copy
        }
        func publish() {
            guard progress != nil, Date().timeIntervalSince(last) >= 0.6 else { return }
            last = Date(); snapshotBudget = 1500; progress?(ScanProgress(root: snapshot(root, 0), errors: errors, count: count))
        }
        func addPreview(_ parent: Node, _ child: Node) {
            if parent.preview.count < 24 { parent.preview.append(child) }
            else if let minIndex = parent.preview.indices.min(by: { parent.preview[$0].bytes < parent.preview[$1].bytes }), child.bytes > parent.preview[minIndex].bytes { parent.preview[minIndex] = child }
        }
        func visit(_ node: Node, _ inherited: FileKind?) throws {
            try Task.checkCancellation()
            count += 1
            if node.directory {
                guard stack.count < 512 else { if errors.count < 500 { errors.append("\(node.url.path)：目录层级超过 512，已跳过。"); }; return }
                stack.append(node)
                defer { stack.removeLast() }
                do {
                    // URLs are temporary. Siblings retain the same compact parent location.
                    let directoryURL = node.url
                    let location = DirectoryLocation(directoryURL)
                    guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { path, error in
                        report(path, error); return !Task.isCancelled
                    }) else {
                        report(node.url, NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)); return
                    }
                    while let childURL = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
                        try Task.checkCancellation()
                        do {
                            let child: Node = try autoreleasepool {
                                var metadata = stat()
                                guard lstat(childURL.path, &metadata) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                                let type = metadata.st_mode & S_IFMT
                                let isDir = type == S_IFDIR
                                let kind = inherited ?? FileKind.classify(childURL)
                                let n = Node(name: childURL.lastPathComponent, location: location, directory: isDir, kind: kind)
                                if type == S_IFREG { n.bytes = metadata.st_size; n.diskBytes = max(0, Int64(metadata.st_blocks)) * 512; n.scannedIdentity = ScanIdentity(metadata) }
                                return n
                            }
                            if child.directory { child.parent = node; child.diskBytes = 0 }
                            node.children.append(child)
                            if child.directory { try visit(child, inherited ?? (child.kind == .application ? .application : nil)) }
                            else { count += 1; for ancestor in stack { ancestor.bytes += child.bytes; ancestor.diskBytes = (ancestor.diskBytes ?? 0) + child.footprint } }
                            addPreview(node, child)
                            if count % 256 == 0 { publish() }
                        } catch is CancellationError { throw CancellationError() }
                        catch { report(childURL, error) }
                    }
                    try Task.checkCancellation()
                    // Stable size sort keeps equal-size enumeration order; avoids costly name sorting for millions of empty files.
                    node.children.sort { $0.footprint > $1.footprint }
                } catch is CancellationError { throw CancellationError() }
                catch { report(node.url, error) }
            }
        }
        _ = try url.resourceValues(forKeys: [.isDirectoryKey])
        try visit(root, root.kind == .application ? .application : nil)
        return ScanResult(root: root, errors: errors, count: count)
    }
}
struct Tile { let node: Node; let rect: CGRect; var depth = 0 }
enum Layout {
    static func tiles(_ nodes: [Node], _ rect: CGRect) -> [Tile] {
        let nodes = nodes.filter { $0.footprint > 0 }
        guard !nodes.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        // Balanced partitions avoid highly skewed geometry and recursion over every sibling.
        func divide(_ range: Range<Int>, _ r: CGRect, _ total: Double) -> [Tile] {
            if range.count == 1 { return [Tile(node: nodes[range.lowerBound], rect: r)] }
            var sum = 0.0; var split = range.lowerBound + 1
            for i in range.lowerBound..<(range.upperBound - 1) { sum += Double(nodes[i].footprint); split = i + 1; if sum >= total / 2 { break } }
            let ratio = sum / total; var a = r, b = r
            if r.width >= r.height { a.size.width *= ratio; b.origin.x += a.width; b.size.width -= a.width }
            else { a.size.height *= ratio; b.origin.y += a.height; b.size.height -= a.height }
            return divide(range.lowerBound..<split, a, sum) + divide(split..<range.upperBound, b, total - sum)
        }
        return divide(nodes.indices, rect, nodes.reduce(0.0) { $0 + Double($1.footprint) })
    }
    static func groupedChildren(_ node: Node, rect: CGRect) -> [Node] {
        let candidates = visibleChildren(node)
        let total = candidates.reduce(0.0) { $0 + Double($1.footprint) }
        guard total > 0 else { return candidates }
        let area = max(0, rect.width * rect.height)
        var large: [Node] = [], small: [Node] = []
        for child in candidates {
            if child.footprint == 0 || Double(child.footprint) / total * area < 1600 { small.append(child) }
            else { large.append(child) }
        }
        // Avoid grouping the entire view into itself when everything is equally small.
        guard !small.isEmpty, !large.isEmpty else { return candidates }
        let group = Node(node.url, true, synthetic: true)
        group.label = "过小项目（\(small.count) 项，双击单独展示）"
        group.children = ArraySlice(small); group.parent = node
        group.bytes = small.reduce(0) { $0 + $1.bytes }
        group.diskBytes = small.reduce(0) { $0 + $1.footprint }
        return (large + [group]).sorted { $0.footprint > $1.footprint }
    }
    static func visibleChildren(_ node: Node) -> [Node] {
        guard node.children.count > 180 else { return Array(node.children) }
        let rest = Node(node.url, true, synthetic: true)
        rest.parent = node
        rest.label = "其余 \(node.children.count - 160) 项（双击展开）"
        rest.children = node.children.dropFirst(160); rest.bytes = rest.children.reduce(0) { $0 + $1.bytes }; rest.diskBytes = rest.children.reduce(0) { $0 + $1.footprint }
        return Array(node.children.prefix(160)) + [rest]
    }
}
struct Projection: @unchecked Sendable { let root: Node; let largest: [Node]; let files: Int }
enum Projector {
    static func make(_ source: Node, kind: FileKind) throws -> Projection {
        var top: [Node] = [], files = 0
        func copy(_ node: Node) throws -> Node? {
            try Task.checkCancellation()
            if !node.directory {
                guard kind == .all || node.kind == kind else { return nil }
                if !node.synthetic {
                    files += 1
                    if top.count < 100 || node.footprint > (top.last?.footprint ?? 0) {
                        top.append(node); top.sort { $0.footprint > $1.footprint }; if top.count > 100 { top.removeLast() }
                    }
                }
                return node
            }
            if kind == .all { for child in node.children { _ = try copy(child) }; return node }
            let children = try node.children.compactMap { try copy($0) }
            guard kind == .all || !children.isEmpty else { return nil }
            if kind == .all { return node }
            let n = Node(node.url, true, kind: node.kind, synthetic: node.synthetic); n.label = node.label; n.source = node; n.children = ArraySlice(children.sorted { $0.footprint > $1.footprint }); n.bytes = children.reduce(0) { $0 + $1.bytes }; n.diskBytes = children.reduce(0) { $0 + $1.footprint }; return n
        }
        let root = try copy(source) ?? Node(source.url, true)
        return Projection(root: root, largest: top, files: files)
    }
}
struct ScanIdentity: Equatable, Sendable {
    let inode: UInt64, modified: Int64, changed: Int64
    let device: Int32, modifiedNanos: Int32, changedNanos: Int32
    init(_ s: stat) {
        inode = s.st_ino; device = s.st_dev
        modified = Int64(s.st_mtimespec.tv_sec); changed = Int64(s.st_ctimespec.tv_sec)
        modifiedNanos = Int32(s.st_mtimespec.tv_nsec); changedNanos = Int32(s.st_ctimespec.tv_nsec)
    }
}
struct FileStamp: Equatable, Sendable {
    let identity: ScanIdentity, bytes: Int64
    var device: Int32 { identity.device }; var inode: UInt64 { identity.inode }
    init(_ s: stat) { identity = ScanIdentity(s); bytes = s.st_size }
    static func read(_ url: URL) throws -> FileStamp {
        var s = stat()
        guard lstat(url.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else { throw ServiceError.text("不是可操作的普通文件，符号链接和目录不可移入废纸篓。") }
        return FileStamp(s)
    }
}
struct DirectoryIdentity: Equatable, Sendable {
    let path: String, device: Int32, inode: UInt64
}
struct TrashTicket: Sendable {
    let url: URL, root: URL, stamp: FileStamp, parents: [DirectoryIdentity]
}
enum ServiceError: LocalizedError { case text(String); var errorDescription: String? { if case let .text(s) = self { return s }; return nil } }
enum TrashPolicy {
    static let protected = ["/Applications", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/dev", "/cores", "/.vol", "/.Trash"]
    static func inside(_ path: String, _ root: String) -> Bool { path.hasPrefix(root == "/" ? "/" : root + "/") && path != root }
    static func validate(_ url: URL, root: URL) throws -> FileStamp {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        guard inside(p, r) else { throw ServiceError.text("禁止操作扫描根目录或扫描范围外的项目。") }
        guard p == url.resolvingSymlinksInPath().standardizedFileURL.path, r == root.resolvingSymlinksInPath().standardizedFileURL.path else { throw ServiceError.text("路径包含符号链接，已禁止操作。") }
        guard !protected.contains(where: { p == $0 || inside(p, $0) }) else { throw ServiceError.text("系统保护目录禁止移入废纸篓。") }
        guard !p.split(separator: "/").contains(where: { [".Trash", ".Trashes"].contains(String($0)) }) else { throw ServiceError.text("废纸篓中的项目不可再次操作。") }
        return try FileStamp.read(url)
    }
    static func parents(_ url: URL) throws -> [DirectoryIdentity] {
        var result: [DirectoryIdentity] = [], cursor = url.deletingLastPathComponent()
        while true {
            var s = stat()
            guard lstat(cursor.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else { throw ServiceError.text("父目录类型或路径发生变化，操作已中止。") }
            result.append(DirectoryIdentity(path: cursor.path, device: s.st_dev, inode: s.st_ino))
            if cursor.path == "/" { break }; cursor.deleteLastPathComponent()
        }
        return result
    }
    static func prepare(_ url: URL, root: URL, scannedIdentity: ScanIdentity, scannedBytes: Int64) throws -> TrashTicket {
        let stamp = try validate(url, root: root)
        guard stamp.identity == scannedIdentity, stamp.bytes == scannedBytes else { throw ServiceError.text("文件身份或内容自扫描后发生变化。拒绝操作，请重新扫描。") }
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | SF_RESTRICTED) == 0 else { throw ServiceError.text("文件受系统标志保护，禁止操作。") }
        let chain = try parents(url)
        guard try FileStamp.read(url) == stamp else { throw ServiceError.text("检查期间文件发生变化，请重新扫描。") }
        return TrashTicket(url: url, root: root, stamp: stamp, parents: chain)
    }
    static func moveConfirmed(_ ticket: TrashTicket) throws {
        let current = try prepare(ticket.url, root: ticket.root, scannedIdentity: ticket.stamp.identity, scannedBytes: ticket.stamp.bytes)
        guard current.parents == ticket.parents, current.stamp == ticket.stamp else { throw ServiceError.text("确认后文件身份、类型或父目录发生变化。操作已中止，请重新扫描。") }
        let handle = try Duplicates.opened(ticket.url, stamp: ticket.stamp)
        defer { try? handle.close() }
        guard try FileStamp.read(ticket.url) == ticket.stamp else { throw ServiceError.text("操作前身份重检失败。") }
        try FileManager.default.trashItem(at: ticket.url, resultingItemURL: nil)
    }

}
struct DuplicateGroup: Identifiable, @unchecked Sendable {
    let id = UUID(); let files: [Node]; let bytes: Int64
}
struct DuplicateResult: @unchecked Sendable { let groups: [DuplicateGroup]; let skipped: Int }
enum Duplicates {
    static func opened(_ url: URL, stamp: FileStamp) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ServiceError.text("无法读取文件。") }
        var s = stat()
        guard fstat(fd, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG, FileStamp(s) == stamp else { close(fd); throw ServiceError.text("文件发生变化。") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func hash(_ n: Node, stamp: FileStamp, sampled: Bool) throws -> String {
        let h = try opened(n.url, stamp: stamp); defer { try? h.close() }; var digest = SHA256(); var readBytes: Int64 = 0
        if sampled {
            for offset in Set([Int64(0), max(0, stamp.bytes / 2 - 2048), max(0, stamp.bytes - 4096)]).sorted() {
                try Task.checkCancellation(); try h.seek(toOffset: UInt64(offset)); digest.update(data: try h.read(upToCount: 4096) ?? Data())
            }
        } else {
            while true {
                try Task.checkCancellation()
                let finished = try autoreleasepool { () throws -> Bool in
                    let data = try h.read(upToCount: 1_048_576) ?? Data()
                    if data.isEmpty { return true }; readBytes += Int64(data.count); digest.update(data: data); return false
                }
                if finished { break }
            }
        }
        guard (sampled || readBytes == stamp.bytes), try FileStamp.read(n.url) == stamp else { throw ServiceError.text("文件发生变化。") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func equal(_ a: Node, _ b: Node, _ sa: FileStamp, _ sb: FileStamp) throws -> Bool {
        let ah = try opened(a.url, stamp: sa), bh = try opened(b.url, stamp: sb)
        defer { try? ah.close(); try? bh.close() }
        var readBytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let state = try autoreleasepool { () throws -> (Bool, Bool) in
                let x = try ah.read(upToCount: 1_048_576) ?? Data(), y = try bh.read(upToCount: 1_048_576) ?? Data()
                readBytes += Int64(x.count); return (x == y, x.isEmpty)
            }
            if !state.0 { return false }; if state.1 { break }
        }
        let finalA = try FileStamp.read(a.url), finalB = try FileStamp.read(b.url)
        return readBytes == sa.bytes && finalA == sa && finalB == sb
    }
    static func find(_ root: Node) throws -> DuplicateResult {
        var sizes: [Int64: [Node]] = [:], skipped = 0
        func visit(_ n: Node) throws {
            try Task.checkCancellation()
            if n.directory { for c in n.children { try visit(c) } }
            else if n.bytes > 0 && !n.synthetic { sizes[n.bytes, default: []].append(n) }
        }
        try visit(root); var output: [DuplicateGroup] = []
        for nodes in sizes.values where nodes.count > 1 {
            var seen = Set<String>(), samples: [String: [(Node, FileStamp)]] = [:]
            for n in nodes {
                try Task.checkCancellation()
                do {
                    let s = try autoreleasepool { try FileStamp.read(n.url) }; guard s.bytes == n.bytes, n.scannedIdentity == s.identity else { skipped += 1; continue }
                    guard seen.insert("\(s.device):\(s.inode)").inserted else { skipped += 1; continue }
                    samples[try autoreleasepool { try hash(n, stamp: s, sampled: true) }, default: []].append((n,s))
                } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
            }
            for candidates in samples.values where candidates.count > 1 {
                var hashes: [String: [(Node, FileStamp)]] = [:]
                for (n,s) in candidates {
                    do { hashes[try autoreleasepool { try hash(n, stamp: s, sampled: false) }, default: []].append((n,s)) }
                    catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
                }
                for same in hashes.values where same.count > 1 {
                    var verified: [[(Node,FileStamp)]] = []
                    for item in same {
                        var found = false
                        do {
                            for i in verified.indices {
                                if try autoreleasepool(invoking: { try equal(verified[i][0].0, item.0, verified[i][0].1, item.1) }) { verified[i].append(item); found = true; break }
                            }
                            if !found { verified.append([item]) }
                        } catch is CancellationError { throw CancellationError() } catch { skipped += 1 }
                    }
                    for group in verified where group.count > 1 {
                        let stable = group.filter { item in autoreleasepool { (try? FileStamp.read(item.0.url)) == item.1 } }
                        if stable.count > 1 { output.append(DuplicateGroup(files: stable.map { $0.0 }, bytes: stable[0].1.bytes)) }
                    }
                }
            }
        }
        output.sort { Double($0.bytes) * Double($0.files.count - 1) > Double($1.bytes) * Double($1.files.count - 1) }
        return DuplicateResult(groups: output, skipped: skipped)
    }
}
struct DirectoryRecord: Codable, Sendable { let path: String; let bytes: Int64 }
struct DiskSnapshot: Codable, Identifiable, Sendable {
    let id: UUID, date: Date, root: String, bytes: Int64, count: Int, warnings: Int, directories: [DirectoryRecord]
    static func make(_ node: Node, count: Int, warnings: Int) throws -> DiskSnapshot {
        var records: [DirectoryRecord] = []; let prefix = node.url.path
        func walk(_ n: Node) throws {
            try Task.checkCancellation(); guard records.count < 200000 else { throw ServiceError.text("目录过多，快照未保存（上限 20 万目录）。") }
            let p = n.url.path; records.append(DirectoryRecord(path: p == prefix ? "." : String(p.dropFirst(prefix == "/" ? 1 : prefix.count + 1)), bytes: n.bytes))
            for c in n.children where c.directory { try walk(c) }
        }
        try walk(node)
        return DiskSnapshot(id: UUID(), date: Date(), root: prefix, bytes: node.bytes, count: count, warnings: warnings, directories: records)
    }
}
enum SnapshotStore {
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DiskMap/Snapshots", isDirectory: true) }
    static let maxCount = 30, maxStoreBytes = 64 * 1024 * 1024, maxFileBytes = 4 * 1024 * 1024, maxLoadedBytes = 8 * 1024 * 1024
    private static let lock = NSLock()
    private struct Entry { let url: URL, bytes: Int, date: Date }
    private static func entries(_ folder: URL) throws -> [Entry] {
        guard folder.standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path else { throw ServiceError.text("快照目录包含符号链接，已拒绝读写。") }
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard urls.count <= 10000 else { throw ServiceError.text("快照目录项目过多，请先在 Finder 中整理。") }
        return try urls.filter { $0.pathExtension == "json" }.compactMap { url in
            let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard v.isRegularFile == true, v.isSymbolicLink != true else { return nil }
            return Entry(url: url, bytes: v.fileSize ?? 0, date: v.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }
    static func validate(_ s: DiskSnapshot) throws {
        guard s.root.hasPrefix("/"), s.bytes >= 0, s.count >= 0, s.warnings >= 0, s.date.timeIntervalSince1970.isFinite, s.directories.count <= 200000,
              s.directories.allSatisfy({ $0.bytes >= 0 && $0.bytes <= s.bytes }), Set(s.directories.map { $0.path }).count == s.directories.count else { throw ServiceError.text("快照记录无效，已拒绝读取或对比。") }
    }
    private static func totalBytes(_ entries: [Entry]) -> Int {
        var total = 0
        for e in entries { let (next, overflow) = total.addingReportingOverflow(e.bytes); if overflow { return Int.max }; total = next }
        return total
    }
    static func save(_ s: DiskSnapshot, to folder: URL = directory) throws {
        try validate(s); try Task.checkCancellation()
        let data = try JSONEncoder().encode(s)
        guard data.count <= maxFileBytes else { throw ServiceError.text("单份快照超过 4 MiB，未保存；请缩小扫描范围。") }
        lock.lock(); defer { lock.unlock() }
        let existing = try entries(folder)
        guard existing.count < maxCount, totalBytes(existing) <= maxStoreBytes - data.count else { throw ServiceError.text("快照达到 30 份或 64 MiB 上限。请在历史中明确移入废纸篓后再保存；不会自动删除。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: folder.appendingPathComponent(s.id.uuidString + ".json"), options: .atomic)
    }
    struct Loaded: Sendable { let snapshots: [DiskSnapshot]; let skipped: Int; let totalBytes: Int; let totalCount: Int }
    static func loadDetailed(from folder: URL = directory) throws -> Loaded {
        lock.lock(); defer { lock.unlock() }
        let files = try entries(folder); var result: [DiskSnapshot] = [], loadedBytes = 0, skipped = 0
        for file in files {
            try Task.checkCancellation()
            guard result.count < maxCount, file.bytes <= maxFileBytes, loadedBytes + file.bytes <= maxLoadedBytes else { skipped += 1; continue }
            do {
                let stamp = try FileStamp.read(file.url)
                guard stamp.bytes <= maxFileBytes else { skipped += 1; continue }
                let handle = try Duplicates.opened(file.url, stamp: stamp)
                let data: Data
                do { data = try handle.read(upToCount: maxFileBytes + 1) ?? Data(); try handle.close() }
                catch { try? handle.close(); throw error }
                guard data.count <= maxFileBytes, loadedBytes + data.count <= maxLoadedBytes, try FileStamp.read(file.url) == stamp else { skipped += 1; continue }
                let item = try JSONDecoder().decode(DiskSnapshot.self, from: data); try validate(item)
                guard file.url.lastPathComponent == item.id.uuidString + ".json" else { skipped += 1; continue }
                result.append(item); loadedBytes += data.count
            } catch { skipped += 1 }
        }
        return Loaded(snapshots: result.sorted { $0.date > $1.date }, skipped: skipped, totalBytes: totalBytes(files), totalCount: files.count)
    }
    static func load(from folder: URL = directory) throws -> [DiskSnapshot] { try loadDetailed(from: folder).snapshots }
    static func snapshotURL(_ id: UUID, in folder: URL = directory) -> URL { folder.appendingPathComponent(id.uuidString + ".json") }
    static func compare(_ newer: DiskSnapshot, _ older: DiskSnapshot) throws -> [String] {
        try validate(newer); try validate(older)
        guard newer.root == older.root else { throw ServiceError.text("只能对比同一扫描根目录的快照。") }
        guard Set(older.directories.map { $0.path }).count == older.directories.count, Set(newer.directories.map { $0.path }).count == newer.directories.count else { throw ServiceError.text("快照目录记录重复，无法对比。") }
        let a = Dictionary(uniqueKeysWithValues: older.directories.map { ($0.path,$0.bytes) }), b = Dictionary(uniqueKeysWithValues: newer.directories.map { ($0.path,$0.bytes) })
        return Set(a.keys).union(b.keys).map { ($0, (b[$0] ?? 0) - (a[$0] ?? 0)) }.filter { $0.1 != 0 }.sorted { abs($0.1) > abs($1.1) }.prefix(200).map { "\($0.0)：\($0.1 > 0 ? "+" : "−")\(size(abs($0.1)))" }
    }
}

@MainActor final class Model: ObservableObject {
    @Published var regions: [Node] = []
    @Published var requestedRegion: Node?
    func selectRegion(_ n: Node, extending: Bool) {
        selected = n
        if extending {
            if let i = regions.firstIndex(where: { $0.id == n.id }) { regions.remove(at: i) }
            else { regions.append(n) }
        } else { regions = [n] }
    }
    func regionGroup() -> Node? {
        let candidates = regions.isEmpty ? selected.map { [$0] } ?? [] : regions
        var unique: [Node] = []
        for candidate in candidates {
            let n = candidate.source ?? candidate
            if !unique.contains(where: { $0 === n }) { unique.append(n) }
        }
        let roots = unique.filter { n in
            !unique.contains { other in other !== n && other.directory && TrashPolicy.inside(n.url.standardizedFileURL.path, other.url.standardizedFileURL.path) }
        }
        guard !roots.isEmpty else { return nil }
        let group = Node(URL(fileURLWithPath: "/"), true, synthetic: true)
        group.label = "所选 \(roots.count) 个区域"; group.children = ArraySlice(roots.sorted { $0.footprint > $1.footprint })
        group.bytes = roots.reduce(0) { $0 + $1.bytes }; group.diskBytes = roots.reduce(0) { $0 + $1.footprint }
        return group
    }

    @Published var root: Node?
    @Published var path: [Node] = []
    @Published var selected: Node?
    @Published var cancelling = false
    @Published var busy = false
    @Published var preparing = false
    @Published var errors: [String] = []
    @Published var count = 0
    @Published var largest: [Node] = []
    @Published var kind: FileKind = .all { didSet { if path.last?.synthetic == true { home() } else { project() } } }
    @Published var zoom: CGFloat = 1
    @Published var depth = 3
    @Published var tab = 0
    @Published var ascending = false
    @Published var listLimit = 200
    @Published var hoverText = ""
    @Published var elapsed = 0.0
    @Published var partial = false
    let quickVolumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    @Published var utilityBusy = false
    @Published var notice = ""
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var showDuplicates = false
    @Published var showHistory = false
    @Published var history: [DiskSnapshot] = []
    @Published var historyStatus = ""
    @Published var comparison = ""
    @Published var baselineID: UUID?
    private var duplicateJobRunning = false
    var utilityTask: Task<Void, Never>?
    var task: Task<Void, Never>?, projectionTask: Task<Void, Never>?
    private var generation = UUID(), revision = UUID()
    var current: Node? { path.last }
    func choose() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        // Do not reopen a million-item folder just to choose the next scan root.
        panel.directoryURL = root?.url.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { start(url) }
    }
    func start(_ url: URL) {
        guard !busy && !utilityBusy else { return }
        // Keep the previous frozen tree alive until AppKit has detached its old views,
        // then release it on a worker instead of destroying millions of nodes on the UI thread.
        let retiredDuplicates = duplicateGroups
        duplicateGroups = []; notice = ""; history = []; comparison = ""; baselineID = nil
        let retired = [root, display, selected].compactMap { $0 } + path + largest
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            withExtendedLifetime((retired, retiredDuplicates)) {}
        }
        projectionTask?.cancel(); revision = UUID(); preparing = false; listLimit = 200; hoverText = ""; display = nil; root = nil; path = []; selected = nil; regions = []; errors = []; largest = []; count = 0; elapsed = 0; partial = true; busy = true; cancelling = false; zoom = 1
        let token = UUID(); generation = token
        let started = Date()
        task = Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() }; if generation == token { busy = false; cancelling = false; elapsed = Date().timeIntervalSince(started); task = nil } }
            let (stream, continuation) = AsyncStream<ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let worker = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                do {
                    let result = try Scanner.scan(url) { continuation.yield($0) }
                    try Task.checkCancellation()
                    return result
                } catch { throw error }
            }
            await withTaskCancellationHandler {
                for await update in stream {
                    guard generation == token, !Task.isCancelled else { continue }
                    root = update.root; errors = update.errors; count = update.count; elapsed = Date().timeIntervalSince(started)
                    if path.count <= 1 { path = [update.root] }
                    // Preview has a bounded tree; filter and ranking are prepared off the main thread.
                    project()
                }
            } onCancel: { worker.cancel() }
            do {
                let result = try await worker.value; try Task.checkCancellation()
                root = result.root; count = result.count; errors = result.errors; partial = false
                path = [result.root]; selected = nil; project()
            } catch is CancellationError { errors.append("扫描已取消。当前显示已扫描的部分数据，可重新选择文件夹扫描。") }
            catch { errors.append(Scanner.message(error)) }
        }
    }
    func project() {
        projectionTask?.cancel()
        guard let source = path.last ?? root else { return }
        let filter = kind, token = UUID(); revision = token; preparing = true
        projectionTask = Task {
            defer { if revision == token { projectionTask = nil } }
            let worker = Task.detached(priority: .userInitiated) { try Projector.make(source, kind: filter) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation(); guard revision == token else { return }
                display = result.root; largest = result.largest; preparing = false
            } catch { if revision == token { preparing = false } }
        }
    }
    @Published var display: Node?
    func enter(_ node: Node) {
        selected = node
        guard node.directory else { return }
        let target = node.source ?? node
        if target.synthetic { path.append(target) }
        else {
            var chain: [Node] = [], cursor: Node? = target
            while let n = cursor { chain.append(n); if n.id == root?.id { break }; cursor = n.parent }
            if chain.last?.id == root?.id { path = chain.reversed() } else { path.append(target) }
        }
        zoom = 1; project()
    }
    func back() { guard path.count > 1 else { return }; path.removeLast(); selected = nil; zoom = 1; project() }
    func home() { if let root { path = [root]; selected = nil; zoom = 1; project() } }
    func reveal(_ n: Node) { guard !n.synthetic else { return }; NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
}
struct MapView: NSViewRepresentable {
    let node: Node; @ObservedObject var model: Model
    func makeNSView(context: Context) -> MapCanvas { MapCanvas() }
    func updateNSView(_ view: MapCanvas, context: Context) {
        let changed = view.node !== node || view.levels != model.depth
        view.node = node; view.model = model; view.levels = model.depth
        let ids = Set(model.regions.map { $0.id })
        let selectionChanged = view.selectedID != model.selected?.id || view.regionIDs != ids
        view.regionIDs = ids
        view.selectedID = model.selected?.id
        if changed { view.invalidateGeometry() }
        if changed || selectionChanged { view.needsDisplay = true }
    }
}
final class MapCanvas: NSView {
    var node: Node?; weak var model: Model?; var levels = 3
    var selectedID: ObjectIdentifier?
    var regionIDs: Set<ObjectIdentifier> = []
    private var captions: [String] = []
    private let paragraph: NSMutableParagraphStyle = { let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; return p }()
    private var tiles: [Tile] = [], geometrySize = CGSize.zero
    private var hovered: Node?, tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    func invalidateGeometry() { geometrySize = .zero }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t; super.updateTrackingAreas()
    }
    private func build() {
        guard geometrySize != bounds.size else { return }; geometrySize = bounds.size; tiles = []
        func descend(_ n: Node, _ r: CGRect, _ depth: Int) {
            guard tiles.count < 2500 else { return }
            for var tile in Layout.tiles(Layout.groupedChildren(n, rect: r), r) {
                if tiles.count >= 2500 { break }
                guard tile.rect.width >= 2 && tile.rect.height >= 2 else { continue }
                tile.depth = depth; tiles.append(tile)
                if tile.node.directory && !tile.node.synthetic && depth < levels && tile.rect.width > 65 && tile.rect.height > 60 {
                    let inner = CGRect(x: tile.rect.minX + 4, y: tile.rect.minY + 23, width: tile.rect.width - 8, height: tile.rect.height - 27)
                    descend(tile.node, inner, depth + 1)
                }
            }
        }
        if let node { descend(node, bounds.insetBy(dx: 5, dy: 5), 1) }
        captions = tiles.map { "\($0.node.directory ? "▸ " : "")\($0.node.name) · \(size($0.node.footprint))" }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill(); build()
        for (index, tile) in tiles.enumerated() where tile.rect.intersects(dirtyRect) {
            let n = tile.node, r = tile.rect.insetBy(dx: 1, dy: 1)
            let colorIndex = FileKind.allCases.firstIndex(of: n.kind) ?? 0
            let hue = n.directory ? 0.59 : CGFloat(colorIndex) / CGFloat(FileKind.allCases.count)
            NSColor(calibratedHue: hue, saturation: n.directory ? 0.36 : 0.53, brightness: max(0.35, 0.78 - CGFloat(tile.depth) * 0.07), alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            if regionIDs.contains(n.id) || model?.selected?.id == n.id || hovered?.id == n.id {
                NSColor.selectedControlColor.setStroke(); let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); p.lineWidth = 3; p.stroke()
            }
            if r.width > 50 && r.height > 23 {
                (captions[index] as NSString).draw(in: CGRect(x: r.minX + 5, y: r.minY + 4, width: r.width - 10, height: 18), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: paragraph])
            }
        }
        if tiles.isEmpty {
            ("没有符合条件的非零文件；可通过右侧列表查看空目录。" as NSString).draw(at: CGPoint(x: 16,y: 20), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
        }
    }
    private func hit(_ event: NSEvent) -> Node? {
        build(); let point = convert(event.locationInWindow, from: nil)
        return tiles.reversed().first(where: { $0.rect.contains(point) })?.node
    }
    override func mouseMoved(with event: NSEvent) {
        let n = hit(event); guard n?.id != hovered?.id else { return }
        let old = hovered; hovered = n
        for tile in tiles where tile.node === old || tile.node === n { setNeedsDisplay(tile.rect) }
        toolTip = n.map { "\($0.name)\n\(size($0.footprint)) 磁盘占用 · 逻辑 \(size($0.bytes))\n\($0.url.path)\n\($0.directory ? "双击进入文件夹" : $0.kind.rawValue)" }
        model?.hoverText = n.map { "\($0.name) · \(size($0.footprint)) · \($0.kind.rawValue)" } ?? ""
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; toolTip = nil; model?.hoverText = ""; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        if let n = hit(event) { if event.clickCount == 2 { if n.synthetic { model?.requestedRegion = n } else { model?.enter(n) } } else { model?.selectRegion(n, extending: event.modifierFlags.contains(.command)) } }
    }
    private var contextDirectory: Node?
    override func rightMouseDown(with event: NSEvent) {
        build()
        let point = convert(event.locationInWindow, from: nil)
        // Use the smallest visible enclosing directory, even when the hit file is too small to select reliably.
        contextDirectory = tiles.reversed().first(where: { $0.node.directory && $0.rect.contains(point) })?.node ?? node
        let menu = NSMenu()
        let expand = NSMenuItem(title: "单独展示此处全部项目", action: #selector(expandContextDirectory), keyEquivalent: "")
        expand.target = self; expand.isEnabled = contextDirectory != nil; menu.addItem(expand)
        let back = NSMenuItem(title: "返回上一级", action: #selector(contextBack), keyEquivalent: "")
        back.target = self; back.isEnabled = (model?.path.count ?? 0) > 1; menu.addItem(back)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func expandContextDirectory() {
        guard let directory = contextDirectory, let model else { return }
        model.requestedRegion = directory
        contextDirectory = nil
    }
    @objc private func contextBack() { model?.back(); contextDirectory = nil }
    override func magnify(with event: NSEvent) { if let model { model.zoom = min(4, max(1, model.zoom * (1 + event.magnification))) } }
}
func size(_ value: Int64) -> String { value == 0 ? "0 字节" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
extension Model {
    func runUtility(_ work: @escaping @Sendable () throws -> String) {
        guard !busy && !utilityBusy else { return }; utilityBusy = true
        utilityTask = Task {
            let worker = Task.detached(priority: .utility) { try work() }
            defer { utilityBusy = false; utilityTask = nil }
            do { notice = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() }) }
            catch is CancellationError { notice = "操作已取消。" }
            catch { notice = error.localizedDescription }
        }
    }
    func confirmTrash(_ candidate: Node? = nil) {
        if let candidate, candidate !== selected { notice = "选中项目已改变，请重新选择后操作。"; return }
        guard !busy && !utilityBusy && !partial, let n = selected, let scanRoot = root, !n.directory, !n.synthetic else { notice = "请在完整扫描后选择普通文件。目录与扫描根目录不可移入废纸篓。"; return }
        do {
            guard let scannedIdentity = n.scannedIdentity else { notice = "此项目没有普通文件身份记录，符号链接等项目禁止操作；若为普通文件，请重新扫描。"; return }
            let url = n.url, rootURL = scanRoot.url
            let ticket = try TrashPolicy.prepare(url, root: rootURL, scannedIdentity: scannedIdentity, scannedBytes: n.bytes)
            let alert = NSAlert(); alert.messageText = "将此文件移入废纸篓？"
            alert.informativeText = "\(url.path)\n逻辑大小：\(size(ticket.stamp.bytes))\n只移动此路径，不会永久删除；可在 Finder 废纸篓中恢复。硬链接的其他路径不会移动。"
            alert.alertStyle = .warning; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移入废纸篓")
            guard alert.runModal() == .alertSecondButtonReturn else { notice = "已取消移入废纸篓。"; return }
            utilityBusy = true
            utilityTask = Task {
                defer { utilityTask = nil }
                do {
                    try await Task.detached { try TrashPolicy.moveConfirmed(ticket) }.value
                    utilityBusy = false; start(rootURL); notice = "已移入系统废纸篓，正在重新扫描更新统计；逻辑减少量不代表释放的物理空间。"
                } catch { utilityBusy = false; notice = "移入失败：\(error.localizedDescription)" }
            }
        } catch { notice = error.localizedDescription }
    }
    func closeDuplicates() {
        if duplicateJobRunning { utilityTask?.cancel() }
        showDuplicates = false
        let retired = duplicateGroups; duplicateGroups = []
        Task.detached(priority: .utility) { withExtendedLifetime(retired) {} }
    }
    func closeHistory() { showHistory = false; history = []; comparison = ""; baselineID = nil }
    func trashSnapshot(_ s: DiskSnapshot) {
        guard !utilityBusy else { return }
        do {
            let url = SnapshotStore.snapshotURL(s.id), stamp = try FileStamp.read(url)
            let ticket = try TrashPolicy.prepare(url, root: SnapshotStore.directory, scannedIdentity: stamp.identity, scannedBytes: stamp.bytes)
            let alert = NSAlert(); alert.messageText = "将此扫描快照移入废纸篓？"
            alert.informativeText = "只移动本软件的快照 JSON，不移动原文件。\n\(s.root)\n\(url.path)"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移入废纸篓")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            utilityBusy = true
            utilityTask = Task {
                defer { utilityBusy = false; utilityTask = nil }
                do {
                    try await Task.detached { try TrashPolicy.moveConfirmed(ticket) }.value
                    let loaded = try await Task.detached { try SnapshotStore.loadDetailed() }.value
                    history = showHistory ? loaded.snapshots : []; baselineID = nil; comparison = showHistory ? "快照已移入系统废纸篓。原扫描文件不受影响。" : ""
                    historyStatus = "共 \(loaded.totalCount) 份 / \(size(Int64(loaded.totalBytes)))；未加载 \(loaded.skipped) 份。"
                } catch { comparison = "操作失败：\(error.localizedDescription)" }
            }
        } catch { comparison = error.localizedDescription }
    }
    func detectDuplicates() {
        guard !busy && !utilityBusy && !partial, let root else { return }
        utilityBusy = true; duplicateJobRunning = true; showDuplicates = true; duplicateGroups = []; notice = "正在检测重复文件：大小分组 → 分块哈希 → 完整哈希与逐字节校验…"
        utilityTask = Task {
            let worker = Task.detached(priority: .utility) { try Duplicates.find(root) }
            defer { utilityBusy = false; duplicateJobRunning = false; utilityTask = nil }
            do {
                let r = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                duplicateGroups = r.groups; notice = "发现 \(r.groups.count) 组重复文件；跳过变化、不可读或重复硬链接路径 \(r.skipped) 项。结果非实时，不代表可回收空间。"
            } catch is CancellationError { notice = "重复检测已取消。" }
            catch { notice = error.localizedDescription }
        }
    }
    func saveSnapshot() {
        guard !partial, let root else { return }; let c = count, w = errors.count
        runUtility { let s = try DiskSnapshot.make(root, count: c, warnings: w); try SnapshotStore.save(s); return "快照已保存到本机 Application Support/DiskMap/Snapshots（目录级逻辑大小，不含文件内容）。" }
    }
    func openHistory() {
        guard !busy && !utilityBusy else { return }; utilityBusy = true
        utilityTask = Task {
            defer { utilityBusy = false; utilityTask = nil }
            do { let loaded = try await Task.detached { try SnapshotStore.loadDetailed() }.value
                history = loaded.snapshots; historyStatus = "共 \(loaded.totalCount) 份 / \(size(Int64(loaded.totalBytes)))；跳过损坏或加载超限 \(loaded.skipped) 份。最多保存 30 份 / 64 MiB；单份 4 MiB，加载合计 8 MiB。"
                showHistory = true; comparison = "选择基准快照，再点另一条的“与基准对比”。仅对比同根目录。" }
            catch { notice = "历史读取失败：\(error.localizedDescription)" }
        }
    }
    func compareSnapshot(_ snapshot: DiskSnapshot) {
        guard let older = history.first(where: { $0.id == baselineID }) else { comparison = "请先设定基准。"; return }
        do {
            let changes = try SnapshotStore.compare(snapshot, older)
            comparison = "对比方向：所选 − 基准。总逻辑大小变化：\(snapshot.bytes - older.bytes) 字节。\n目录层级存在包含关系，不能将各行相加。两份快照错误数：\(older.warnings)、\(snapshot.warnings)。\n" + (changes.isEmpty ? "目录逻辑大小无变化。" : changes.joined(separator: "\n"))
        } catch { comparison = error.localizedDescription }
    }
}
struct DuplicateView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("重复文件（只查看，不自动删除）").font(.headline); Spacer(); Button("关闭并释放结果") { model.closeDuplicates() } }
            Text(model.notice).font(.caption).textSelection(.enabled)
            if model.utilityBusy { ProgressView(); Button("取消检测") { model.utilityTask?.cancel() } }
            List {
                ForEach(Array(model.duplicateGroups.prefix(200))) { group in
                    Section("\(group.files.count) 个文件 · 每个 \(size(group.bytes)) · 已逐字节验证") {
                        ForEach(Array(group.files.prefix(200))) { n in HStack { Text(n.url.path).textSelection(.enabled); Spacer(); Button("Finder 定位") { model.reveal(n) } } }
                        if group.files.count > 200 { Text("本组仅展示前 200 个路径。") }
                    }
                }
            }
            Text("最多展示 200 组、每组 200 个路径；同 inode 硬链接不作为额外重复文件。APFS 克隆可能共享磁盘块。空文件不参与。检测后内容仍可能改变。").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(width: 850, height: 600)
    }
}
struct HistoryView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("扫描快照与历史对比").font(.headline); Spacer(); Button("关闭") { model.closeHistory() } }
            Text("保存目录级逻辑大小、扫描项数及错误数；不保存文件内容，不恢复为可删除的扫描树。").font(.caption)
            Text(model.historyStatus).font(.caption).textSelection(.enabled)
            Text("达到上限会拒绝新增，不自动删除；移入废纸篓必须确认。").font(.caption)
            Button("在 Finder 中查看快照目录") {
                let folder = SnapshotStore.directory
                if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                else { model.comparison = "尚未保存快照，目录还不存在。" }
            }
            List(model.history) { s in
                VStack(alignment: .leading) {
                    Text(s.root).lineLimit(1).truncationMode(.middle)
                    HStack { Text(s.date.formatted()).font(.caption); Text("\(size(s.bytes)) · \(s.count) 项 · \(s.warnings) 条错误").font(.caption); Spacer(); Button(model.baselineID == s.id ? "已设基准" : "设为基准") { model.baselineID = s.id }; Button("与基准对比") { model.compareSnapshot(s) }; Button("快照移入废纸篓…") { model.trashSnapshot(s) }.disabled(model.utilityBusy) }
                }
            }.frame(height: 220)
            ScrollView { Text(model.comparison).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding().frame(width: 900, height: 600)
    }
}
struct QuickScanMenu: View {
    @ObservedObject var model: Model
    var body: some View {
        Menu("快捷扫描") {
            Button("主目录") { model.start(FileManager.default.homeDirectoryForCurrentUser) }
            ForEach(["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Applications"], id: \.self) { name in
                Button(["Desktop":"桌面", "Documents":"文稿", "Downloads":"下载", "Pictures":"图片", "Movies":"影片", "Music":"音乐", "Applications":"个人应用程序"][name] ?? name) { model.start(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)) }
            }
            Divider()
            ForEach(model.quickVolumes, id: \.path) { url in Button("磁盘：\(url.path == "/" ? "启动磁盘" : url.lastPathComponent)") { model.start(url) } }
        }.disabled(model.busy || model.utilityBusy)
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var showTools = false
    @State private var focusNode: Node?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                QuickScanMenu(model: model)
                Button("工具与残留检查") { showTools = true }
                Button("选择文件夹", action: model.choose).disabled(model.busy || model.utilityBusy)
                Button("上一级", action: model.back).disabled(model.path.count < 2)
                Button("根目录", action: model.home).disabled(model.root == nil)
                if model.busy { ProgressView().controlSize(.small); Text(model.cancelling ? "正在取消…" : "正在扫描…"); Button("取消") { model.cancelling = true; model.task?.cancel() }.disabled(model.cancelling) }
                Spacer()
                Picker("文件类型", selection: $model.kind) { ForEach(FileKind.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 165)
                Text("磁盘占用 · 扫描只读").foregroundStyle(.secondary)
            }.padding(12)
            HStack {
                Text(model.current?.url.path ?? "选择文件夹开始分析").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Text("\(model.count.formatted()) 项 · \(model.elapsed, specifier: "%.1f") 秒\(model.partial ? " · 部分数据" : "")").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 8)
            HStack {
                Button("检测重复文件", action: model.detectDuplicates).disabled(model.busy || model.utilityBusy || model.partial || model.root == nil)
                Button("保存扫描快照", action: model.saveSnapshot).disabled(model.busy || model.utilityBusy || model.partial || model.root == nil)
                Button("快照历史", action: model.openHistory).disabled(model.busy || model.utilityBusy)
                if model.utilityBusy { ProgressView().controlSize(.small) }
                Text(model.notice).font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer()
            }.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if let node = model.display {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Text("矩形树图 · 磁盘占用").font(.headline)
                            Button("展示所选区域（\(model.regions.count)）") { focusNode = model.regionGroup() }
                                .disabled((model.regions.isEmpty && model.selected == nil) || model.busy || model.preparing)
                                .help("按住 Command 单击多个矩形，再展示所选区域；父子重叠只保留父区域。")
                            Button("清空选区") { model.regions = []; model.selected = nil }
                            if model.path.count > 1 { Button("返回全图") { model.home() } }
                            Picker("嵌套层数", selection: $model.depth) { ForEach(1...4, id: \.self) { Text("\($0) 层").tag($0) } }.frame(width: 130)
                            Spacer()
                            Button("−") { model.zoom = max(1, model.zoom - 0.5) }
                            Text("\(Int(model.zoom * 100))%").frame(width: 45)
                            Button("＋") { model.zoom = min(4, model.zoom + 0.5) }
                            Button("适合窗口") { model.zoom = 1 }
                        }.padding(10)
                        GeometryReader { geo in
                            ScrollView([.horizontal, .vertical]) {
                                MapView(node: node, model: model).frame(width: max(200, geo.size.width) * model.zoom, height: max(200, geo.size.height) * model.zoom)
                            }
                        }
                        Text(model.hoverText.isEmpty ? "密集小区域：右键→单独展示此处全部项目 · 双击目录深入" : model.hoverText).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.frame(minWidth: 450)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("文件详情").font(.headline)
                        if let n = model.selected {
                            Text(n.name).bold().lineLimit(2)
                            Text(n.url.path).font(.caption).lineLimit(3).textSelection(.enabled)
                            Text("\(size(n.footprint)) 磁盘占用 · 逻辑 \(size(n.bytes)) · \(n.directory ? "文件夹" : n.kind.rawValue)")
                            if !n.synthetic { Button("在 Finder 中显示") { model.reveal(n) }
                                if !n.directory { Button("移入废纸篓…") { model.confirmTrash(n) }.disabled(model.busy || model.utilityBusy || model.partial) } }
                            if n.directory { Button("聚焦此目录") { model.enter(n) } }
                        } else { Text("选择矩形或列表中的项目").foregroundStyle(.secondary) }
                        Divider()
                        Picker("列表", selection: $model.tab) { Text("当前目录").tag(0); Text("大文件排行").tag(1) }.pickerStyle(.segmented)
                        HStack {
                            Text(model.tab == 0 ? "\(node.children.count) 项 · \(size(node.footprint)) 磁盘占用" : "当前目录及子目录 · 前 100 文件").font(.caption)
                            Spacer()
                            Button(model.ascending ? "从小到大 ↑" : "从大到小 ↓") { model.ascending.toggle() }.font(.caption)
                        }
                        if model.preparing { Text("正在整理筛选结果…").font(.caption).foregroundStyle(.secondary) }
                        let items = model.tab == 0 ? node.children : model.largest[...]
                        List {
                        ForEach(model.ascending ? Array(items.reversed().prefix(model.listLimit)) : Array(items.prefix(model.listLimit))) { n in
                            HStack {
                                Image(systemName: n.directory ? "folder.fill" : "doc").foregroundStyle(n.directory ? .blue : .secondary)
                                VStack(alignment: .leading) {
                                    Text(n.name).lineLimit(1)
                                    if model.tab == 1 { Text(n.url.deletingLastPathComponent().path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }
                                Spacer(); Text(size(n.footprint)).font(.caption).monospacedDigit()
                            }.contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.enter(n) }
                                .onTapGesture { model.selectRegion(n, extending: NSEvent.modifierFlags.contains(.command)) }
                                .contextMenu { if !n.synthetic { Button("在 Finder 中显示") { model.reveal(n) } }; if n.directory { Button("聚焦此目录") { model.enter(n) } } }
                                .listRowBackground(model.selected?.id == n.id ? Color.accentColor.opacity(0.15) : Color.clear)
                        }
                        if items.count > model.listLimit { Button("显示更多（已显示 \(model.listLimit) / \(items.count) 项）") { model.listLimit += 200 } }
                        }.listStyle(.inset)
                    }.padding(12).frame(minWidth: 290, idealWidth: 345, maxWidth: 450)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "internaldrive").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(model.busy ? "正在读取文件…" : "磁盘地图").font(.title2)
                    Text(model.busy ? "扫描结果会逐步显示，期间可随时取消。" : "选择文件夹，查看空间分布和大文件。所有扫描均为只读。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !model.errors.isEmpty {
                Divider()
                DisclosureGroup("扫描提示：\(model.errors.count) 条（最多保留 500 条）") {
                    ScrollView { Text(model.errors.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6) }.frame(height: 100)
                }.padding(10)
            }
        }.frame(minWidth: 1100, minHeight: 700)
        .onReceive(model.$requestedRegion) { requested in if let requested { focusNode = requested; model.requestedRegion = nil } }
        .sheet(item: $focusNode) { selected in IsolatedRegionView(node: selected.source ?? selected) }
        .sheet(isPresented: $showTools) { ToolAuditView() }
        .sheet(isPresented: $model.showDuplicates, onDismiss: { model.closeDuplicates() }) { DuplicateView(model: model) }
        .sheet(isPresented: $model.showHistory, onDismiss: { model.closeHistory() }) { HistoryView(model: model) }
    }
}
@main struct DiskMapApp: App {
    var body: some Scene { WindowGroup("磁盘地图") { ContentView() }.defaultSize(width: 1200, height: 780) }
}


struct ToolAuditItem: Identifiable, Sendable {
    let id = UUID()
    let source: String, category: String, path: String
}
enum ToolAudit {
    // Only inspect known metadata locations. Never execute installed tools or installation scripts.
    static func inspect(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [ToolAuditItem] {
        let fm = FileManager.default
        var result: [ToolAuditItem] = []
        let locations: [(String, String, URL, Bool)] = [
            ("Homebrew", "安装记录", URL(fileURLWithPath: "/opt/homebrew/Cellar"), true),
            ("Homebrew Intel", "安装记录", URL(fileURLWithPath: "/usr/local/Cellar"), true),
            ("npm", "全局包记录", URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"), true),
            ("npm Intel", "全局包记录", URL(fileURLWithPath: "/usr/local/lib/node_modules"), true),
            ("pipx", "隔离环境记录", home.appendingPathComponent(".local/share/pipx/venvs"), true),
            ("Cargo", "命令入口（不判定安装来源）", home.appendingPathComponent(".cargo/bin"), true),
            ("用户命令", "命令入口（可能是链接或手工脚本）", home.appendingPathComponent(".local/bin"), true),
            ("Python", "用户版本目录（不判定为残留）", home.appendingPathComponent("Library/Python"), true),
            ("Homebrew", "缓存候选，非卸载残留证明", home.appendingPathComponent("Library/Caches/Homebrew"), false),
            ("pip", "缓存候选，非卸载残留证明", home.appendingPathComponent("Library/Caches/pip"), false),
            ("npm", "缓存候选，可能仍在使用", home.appendingPathComponent(".npm/_cacache"), false)
        ]
        for (source, category, url, enumerate) in locations {
            try Task.checkCancellation()
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                result.append(ToolAuditItem(source: source, category: "位置不是普通目录，未跟随", path: url.path)); continue
            }
            if !enumerate { result.append(ToolAuditItem(source: source, category: category, path: url.path)); continue }
            do {
                let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for entry in entries.prefix(2000) {
                    try Task.checkCancellation()
                    result.append(ToolAuditItem(source: source, category: category, path: entry.path))
                }
                if entries.count > 2000 { result.append(ToolAuditItem(source: source, category: "超过 2000 项，列表已截断", path: url.path)) }
            } catch { result.append(ToolAuditItem(source: source, category: "无法读取：" + Scanner.message(error), path: url.path)) }
        }
        return result
    }
}
struct ToolAuditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ToolAuditItem] = []
    @State private var status = "正在检查已知安装与缓存位置…"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("工具与残留检查").font(.headline); Spacer(); Button("关闭") { dismiss() } }
            Text("独立只读检查，不执行终端工具、不自动删除。安装记录不等于工具可运行；缓存不等于卸载残留。自定义安装位置、虚拟环境及系统 Python 包暂未全面检测。")
                .font(.caption).foregroundStyle(.secondary)
            Text(status)
            List(items) { item in
                VStack(alignment: .leading) {
                    HStack { Text(item.source).bold(); Text(item.category).foregroundStyle(.secondary); Spacer(); Button("Finder 定位") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) } }
                    Text(item.path).font(.caption).textSelection(.enabled)
                }
            }
        }.padding().frame(minWidth: 850, minHeight: 540)
        .task {
            let worker = Task.detached(priority: .utility) { try ToolAudit.inspect() }
            do {
                let found = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation(); items = found
                status = "检查完成：\(found.count) 条记录。尚不自动推断卸载残留，请核对来源和路径。"
            } catch is CancellationError { status = "检查已取消。" }
            catch { status = "检查失败：" + error.localizedDescription }
        }
    }
}


struct IsolatedRegionView: View {
    let node: Node
    @Environment(\.dismiss) private var dismiss
    @StateObject private var isolated = Model()
    @State private var shownCount = 200
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("独立展示 · " + (isolated.current?.name ?? node.name)).font(.headline)
                    Text(isolated.current?.url.path ?? node.url.path).font(.caption).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("上一级") { isolated.back() }.disabled(isolated.path.count < 2)
                Button("所选区域全图") { isolated.home() }
                Button("−") { isolated.zoom = max(1, isolated.zoom - 0.5) }
                Text("\(Int(isolated.zoom * 100))%")
                Button("＋") { isolated.zoom = min(4, isolated.zoom + 0.5) }
                Button("关闭") { dismiss() }
            }.padding()
            Divider()
            if let displayed = isolated.display {
                HSplitView {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        MapView(node: displayed, model: isolated)
                            .frame(width: max(200, geo.size.width) * isolated.zoom, height: max(200, geo.size.height) * isolated.zoom)
                    }
                }
                    VStack(alignment: .leading) {
                        Text("全部项目 · \(displayed.children.count) 项").font(.headline)
                        Text("列表按磁盘占用排序，包含树图中太小或零占用的项目。").font(.caption)
                        List {
                            ForEach(Array(displayed.children.prefix(shownCount))) { item in
                                VStack(alignment: .leading) {
                                    Text(item.name).textSelection(.enabled)
                                    Text("磁盘占用 \(size(item.footprint)) · 逻辑 \(size(item.bytes))").font(.caption)
                                    Text(item.url.path).font(.caption).textSelection(.enabled)
                                    HStack {
                                        if item.directory { Button("查看内部全部项目") { isolated.enter(item); shownCount = 200 } }
                                        if !item.synthetic { Button("Finder 定位") { isolated.reveal(item) } }
                                    }
                                }
                            }
                            if displayed.children.count > shownCount {
                                Button("继续显示后 200 项（剩余 \(displayed.children.count - shownCount) 项）") { shownCount += 200 }
                            }
                        }
                    }.padding(10).frame(minWidth: 300, idealWidth: 360)
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text("此处项目独立展示 · 完整列表可分批查看全部项目 · 不改变原扫描视图").font(.caption).padding(8)
        }
        .frame(minWidth: 1000, minHeight: 650)
        .onAppear {
            isolated.root = node; isolated.path = [node]; isolated.depth = 4
            isolated.project()
        }
        .onReceive(isolated.$requestedRegion) { region in if let region { isolated.enter(region); isolated.requestedRegion = nil; shownCount = 200 } }
        .onDisappear { isolated.projectionTask?.cancel(); isolated.display = nil; isolated.root = nil; isolated.path = []; isolated.largest = []; isolated.selected = nil }
    }
}
