let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("a"))
try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
try Data(repeating: 2, count: 300).write(to: dir.appendingPathComponent("sub/b"))
try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("loop"), withDestinationURL: dir)
let result = try Scanner.scan(dir)
assert(result.root.bytes == 400)
assert(result.errors.isEmpty)
assert(result.root.children.count == 3)
let tiles = Layout.tiles(Array(result.root.children), CGRect(x: 0, y: 0, width: 800, height: 600))
assert(tiles.count == 2)
assert(abs(tiles.reduce(0.0) { $0 + $1.rect.width * $1.rect.height } - 480000) < 0.01)
print("PASS: real scan, nested totals, symlink loop, zero-size exclusion, treemap area")

do { _ = try Scanner.scan(dir.appendingPathComponent("missing")); assertionFailure("missing path accepted") } catch { print("PASS: missing path error") }
let blocked = dir.appendingPathComponent("blocked")
try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
let denied = try Scanner.scan(blocked)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
assert(!denied.errors.isEmpty)
print("PASS: permission error collected")
let semaphore = DispatchSemaphore(value: 0)
let cancel = Task.detached {
    while !Task.isCancelled { await Task.yield() }
    do { _ = try Scanner.scan(dir); assertionFailure("cancel ignored") }
    catch is CancellationError { print("PASS: cancelled scan") }
    catch { assertionFailure("wrong cancellation error") }
    semaphore.signal()
}
cancel.cancel()
assert(semaphore.wait(timeout: .now() + 10) == .success)

let media = dir.appendingPathComponent("media")
try FileManager.default.createDirectory(at: media.appendingPathComponent("Demo.app/Contents"), withIntermediateDirectories: true)
try Data(repeating: 0, count: 500).write(to: media.appendingPathComponent("movie.MP4"))
try Data(repeating: 0, count: 200).write(to: media.appendingPathComponent("photo.heic"))
try Data(repeating: 0, count: 90).write(to: media.appendingPathComponent("Demo.app/Contents/data.bin"))
var previews: [ScanProgress] = []
for i in 0..<600 { try Data(repeating: 0, count: 1).write(to: media.appendingPathComponent("note\(i).txt")) }
let scanned = try Scanner.scan(media) { previews.append($0) }
assert(!previews.isEmpty)
let frozen = previews[0].root.bytes
assert(frozen < scanned.root.bytes)
let video = try Projector.make(scanned.root, kind: .video)
assert(video.root.bytes == 500 && video.largest.count == 1)
let apps = try Projector.make(scanned.root, kind: .application)
assert(apps.root.bytes == 90 && apps.largest.first?.kind == .application)
let all = try Projector.make(scanned.root, kind: .all)
assert(all.root.bytes == 1390 && all.largest.count == 100)
assert(zip(all.largest, all.largest.dropFirst()).allSatisfy { $0.footprint >= $1.footprint })
assert(previews[0].root.bytes == frozen)
assert(Layout.visibleChildren(scanned.root).reduce(0) { $0 + $1.bytes } == scanned.root.bytes)
let group = Layout.visibleChildren(scanned.root).last!
assert(group.synthetic && !group.children.isEmpty)
assert(FileKind.classify(URL(fileURLWithPath: "/file.zip")) == .archive)
assert(FileKind.classify(URL(fileURLWithPath: "/file.pdf")) == .document)
assert(FileKind.classify(URL(fileURLWithPath: "/file.flac")) == .audio)
print("PASS: progressive frozen preview, case-insensitive filters, app inheritance, top 100 sorting, grouped area conservation")

let appFolder = scanned.root.children.first { $0.name == "Demo.app" }!
assert(appFolder.parent === scanned.root)
assert(appFolder.children.first?.parent === appFolder)
print("PASS: physical parent chain for nested navigation")

let links = dir.appendingPathComponent("links")
try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
let original = links.appendingPathComponent("original.bin")
try Data(repeating: 42, count: 8192).write(to: original)
try FileManager.default.linkItem(at: original, to: links.appendingPathComponent("hard.bin"))
try FileManager.default.createSymbolicLink(at: links.appendingPathComponent("symbolic.bin"), withDestinationURL: original)
let linked = try Scanner.scan(links)
assert(linked.root.bytes == 16384)
assert(linked.root.children.first { $0.name == "symbolic.bin" }?.bytes == 0)
let clone = links.appendingPathComponent("clone.bin")
let cloneStatus = clonefile(original.path, clone.path, 0)
if cloneStatus == 0 {
    let cloned = try Scanner.scan(links); assert(cloned.root.bytes == 24576)
    print("PASS: native clonefile succeeded; logical bytes counted per path, hard links repeated, symlink zero")
} else { print("UNVERIFIED: native clonefile unavailable, errno=\(errno)") }
assert(Node(URL(fileURLWithPath: "/"), true).url.path == "/")
for _ in 0..<8 {
    let again = try Scanner.scan(media)
    assert(again.root.bytes == scanned.root.bytes)
    let projection = try Projector.make(again.root, kind: .image)
    assert(projection.root.bytes == 200)
}
print("PASS: eight consecutive scans, directory projections, compact path reconstruction")
let duplicatesDir = dir.appendingPathComponent("duplicates")
try FileManager.default.createDirectory(at: duplicatesDir, withIntermediateDirectories: true)
let content = Data(repeating: 7, count: 30000)
try content.write(to: duplicatesDir.appendingPathComponent("a.bin"))
try content.write(to: duplicatesDir.appendingPathComponent("b.bin"))
var collision = content; collision[6000] = 3
try collision.write(to: duplicatesDir.appendingPathComponent("different.bin"))
try FileManager.default.linkItem(at: duplicatesDir.appendingPathComponent("a.bin"), to: duplicatesDir.appendingPathComponent("hard.bin"))
try FileManager.default.createSymbolicLink(at: duplicatesDir.appendingPathComponent("symbolic.bin"), withDestinationURL: duplicatesDir.appendingPathComponent("a.bin"))
let dupeScan = try Scanner.scan(duplicatesDir)
let dupeResult = try Duplicates.find(dupeScan.root)
assert(dupeResult.groups.count == 1 && dupeResult.groups[0].files.count == 2)
assert(dupeResult.skipped >= 1)
let aNode = dupeScan.root.children.first { $0.name == "a.bin" }!, differentNode = dupeScan.root.children.first { $0.name == "different.bin" }!
let as_ = try FileStamp.read(aNode.url), ds = try FileStamp.read(differentNode.url)
let sampleA = try Duplicates.hash(aNode, stamp: as_, sampled: true), sampleD = try Duplicates.hash(differentNode, stamp: ds, sampled: true)
assert(sampleA == sampleD)
let equality = try Duplicates.equal(aNode, differentNode, as_, ds); assert(!equality)
let firstSnapshot = try DiskSnapshot.make(dupeScan.root, count: dupeScan.count, warnings: 0)
try Data([1,2,3]).write(to: duplicatesDir.appendingPathComponent("new.txt"))
let changedScan = try Scanner.scan(duplicatesDir)
let secondSnapshot = try DiskSnapshot.make(changedScan.root, count: changedScan.count, warnings: 0)
assert(secondSnapshot.bytes - firstSnapshot.bytes == 3)
let store = dir.appendingPathComponent("store")
try SnapshotStore.save(firstSnapshot, to: store); try SnapshotStore.save(secondSnapshot, to: store)
let stored = try SnapshotStore.load(from: store); assert(stored.count == 2)
let delta = try SnapshotStore.compare(secondSnapshot, firstSnapshot); assert(delta.contains { $0.contains("+") })
let policyRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/policy-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: policyRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: policyRoot) }
let safe = policyRoot.appendingPathComponent("test.txt")
try Data([1]).write(to: safe)
let stampBefore = try FileStamp.read(safe)
let ticket = try TrashPolicy.prepare(safe, root: policyRoot, scannedIdentity: stampBefore.identity, scannedBytes: stampBefore.bytes)
for blockedURL in [policyRoot, URL(fileURLWithPath: "/System/Library/test"), dir.appendingPathComponent("a")] {
    do { _ = try TrashPolicy.validate(blockedURL, root: policyRoot); assertionFailure("unsafe path accepted") } catch {}
}
let symlink = policyRoot.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: safe)
do { _ = try TrashPolicy.validate(symlink, root: policyRoot); assertionFailure("symlink accepted") } catch {}
try Data([1,2]).write(to: safe)
do { try TrashPolicy.moveConfirmed(ticket); assertionFailure("changed file moved") } catch {}
assert(FileManager.default.fileExists(atPath: safe.path))
print("PASS: sampled-hash collision rejected by full verification, hard-link exclusion, snapshots round trip/delta, trash root/system/outside/symlink/changed-file protections")
do {
    _ = try TrashPolicy.validate(URL(fileURLWithPath: "/System/Library/nonexistent-test"), root: URL(fileURLWithPath: "/"))
    assertionFailure("system protection did not run")
} catch { assert(error.localizedDescription.contains("系统保护")) }
let changing = dir.appendingPathComponent("changing")
try FileManager.default.createDirectory(at: changing, withIntermediateDirectories: true)
for i in 0..<1500 { try Data([1]).write(to: changing.appendingPathComponent("\(i).txt")) }
var mutated = false
let changingResult = try Scanner.scan(changing) { _ in
    if !mutated { mutated = true; try? FileManager.default.removeItem(at: changing.appendingPathComponent("1499.txt")); try? Data([1,2]).write(to: changing.appendingPathComponent("new.txt")) }
}
assert(mutated && changingResult.root.bytes >= 1499 && changingResult.root.bytes <= 1502)
print("PASS: explicit system directory protection and directory changes during progressive scan without crash")
let identityFile = policyRoot.appendingPathComponent("identity.bin")
try Data([1,2,3,4]).write(to: identityFile)
let identityScan = try Scanner.scan(policyRoot)
let identityNode = identityScan.root.children.first { $0.name == "identity.bin" }!
assert(identityNode.scannedIdentity != nil)
try FileManager.default.moveItem(at: identityFile, to: policyRoot.appendingPathComponent("old-identity.bin"))
try Data([1,2,3,4]).write(to: identityFile)
do { _ = try TrashPolicy.prepare(identityFile, root: policyRoot, scannedIdentity: identityNode.scannedIdentity!, scannedBytes: identityNode.bytes); assertionFailure("scan identity replacement accepted") } catch {}
let pa = policyRoot.appendingPathComponent("parentA"), pb = policyRoot.appendingPathComponent("parentB")
try FileManager.default.createDirectory(at: pa, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: pb, withIntermediateDirectories: true)
try Data([9]).write(to: pa.appendingPathComponent("file"))
try FileManager.default.linkItem(at: pa.appendingPathComponent("file"), to: pb.appendingPathComponent("file"))
let parentFile = pa.appendingPathComponent("file"), parentStamp = try FileStamp.read(parentFile)
let parentTicket = try TrashPolicy.prepare(parentFile, root: policyRoot, scannedIdentity: parentStamp.identity, scannedBytes: parentStamp.bytes)
try FileManager.default.moveItem(at: pa, to: policyRoot.appendingPathComponent("held-parent"))
try FileManager.default.moveItem(at: pb, to: pa)
do { try TrashPolicy.moveConfirmed(parentTicket); assertionFailure("replaced ancestor accepted") } catch {}
assert(FileManager.default.fileExists(atPath: parentFile.path))
let quota = dir.appendingPathComponent("quota-store")
for _ in 0..<30 {
    let snap = DiskSnapshot(id: UUID(), date: Date(), root: "/test", bytes: 1, count: 1, warnings: 0, directories: [DirectoryRecord(path: ".", bytes: 1)])
    try SnapshotStore.save(snap, to: quota)
}
do { try SnapshotStore.save(firstSnapshot, to: quota); assertionFailure("snapshot quota ignored") } catch {}
let quotaFiles = try FileManager.default.contentsOfDirectory(atPath: quota.path); assert(quotaFiles.count == 30)
try Data("not json".utf8).write(to: quota.appendingPathComponent("broken.json"))
let loadedQuota = try SnapshotStore.loadDetailed(from: quota)
assert(loadedQuota.snapshots.count == 30 && loadedQuota.skipped == 1)
let invalidSnapshot = DiskSnapshot(id: UUID(), date: Date(), root: "/test", bytes: -1, count: 0, warnings: 0, directories: [])
do { _ = try SnapshotStore.compare(invalidSnapshot, invalidSnapshot); assertionFailure("negative snapshot accepted") } catch {}
print("PASS: scan-time identity replacement rejected; same-file replaced-parent ticket rejected; snapshot quota and corrupt/negative-record recovery")
let budgetStore = dir.appendingPathComponent("budget-store")
let longRecords = [DirectoryRecord(path: ".", bytes: 1)] + (0..<12000).map { DirectoryRecord(path: "dir\($0)-" + String(repeating: "x", count: 180), bytes: 0) }
for _ in 0..<4 {
    let snap = DiskSnapshot(id: UUID(), date: Date(), root: "/budget", bytes: 1, count: 1, warnings: 0, directories: longRecords)
    try SnapshotStore.save(snap, to: budgetStore)
}
let budgetLoad = try SnapshotStore.loadDetailed(from: budgetStore)
assert(budgetLoad.snapshots.count < 4 && budgetLoad.skipped > 0)
let mismatchStore = dir.appendingPathComponent("mismatch-store")
try FileManager.default.createDirectory(at: mismatchStore, withIntermediateDirectories: true)
try JSONEncoder().encode(firstSnapshot).write(to: mismatchStore.appendingPathComponent(UUID().uuidString + ".json"))
let mismatch = try SnapshotStore.loadDetailed(from: mismatchStore)
assert(mismatch.snapshots.isEmpty && mismatch.skipped == 1)
print("PASS: bounded history decode budget and filename/UUID integrity validation")

let sparseRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: sparseRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: sparseRoot) }
let sparseURL = sparseRoot.appendingPathComponent("virtual-disk.raw")
FileManager.default.createFile(atPath: sparseURL.path, contents: Data())
let sparseHandle = try FileHandle(forWritingTo: sparseURL)
try sparseHandle.truncate(atOffset: 10_000_000_000)
try sparseHandle.close()
let sparseScan = try Scanner.scan(sparseRoot)
assert(sparseScan.root.bytes == 10_000_000_000)
assert(sparseScan.root.footprint < sparseScan.root.bytes)
assert(sparseScan.root.children.first!.diskBytes != nil)
print("PASS: sparse logical size retained; allocated blocks drive footprint")

let smallGroupRoot = Node(URL(fileURLWithPath: "/group-test"), true)
let bigGroupFile = Node(URL(fileURLWithPath: "/group-test/big"), false); bigGroupFile.bytes = 1000000
var smallGroupFiles = [bigGroupFile]
for i in 0..<10 { let f = Node(URL(fileURLWithPath: "/group-test/small\(i)"), false); f.bytes = 10; smallGroupFiles.append(f) }
smallGroupRoot.children = ArraySlice(smallGroupFiles)
let groupedSmall = Layout.groupedChildren(smallGroupRoot, rect: CGRect(x: 0,y: 0,width: 800,height: 600))
assert(groupedSmall.count == 2)
assert(groupedSmall.reduce(0) { $0 + $1.bytes } == 1000100)
assert(groupedSmall.first(where: { $0.synthetic })!.children.count == 10)
print("PASS: tiny items aggregate without losing logical or allocated totals")
