@main struct ModelChecks {
    @MainActor static func settle(_ model: Model) async throws {
        let deadline = Date().addingTimeInterval(45)
        while model.busy || model.preparing || model.utilityBusy {
            guard Date() < deadline else { fatalError("model did not settle") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for i in 0..<1000 { try Data([1]).write(to: a.appendingPathComponent("\(i).txt")) }
        try Data(repeating: 2, count: 400).write(to: b.appendingPathComponent("movie.mp4"))
        let model = Model()
        let parent = Node(URL(fileURLWithPath: "/selection/A"), true)
        let child = Node(URL(fileURLWithPath: "/selection/A/file"), false)
        let sibling = Node(URL(fileURLWithPath: "/selection/B"), true)
        parent.bytes = 100; parent.diskBytes = 4096; child.bytes = 100; child.diskBytes = 4096
        sibling.bytes = 200; sibling.diskBytes = 8192
        model.selectRegion(child, extending: false)
        model.selectRegion(parent, extending: true)
        model.selectRegion(sibling, extending: true)
        let group = model.regionGroup()!
        assert(group.children.count == 2 && group.bytes == 300 && group.footprint == 12288)
        model.selectRegion(sibling, extending: true)
        assert(model.regionGroup()!.children.count == 1)
        model.regions = []; model.selected = nil
        assert(model.regionGroup() == nil)
        print("PASS: multiple regions, toggle selection, parent-child deduplication and allocated totals")

        model.start(a); try await settle(model)
        assert(model.root?.bytes == 1000 && model.display?.bytes == 1000)
        weak var retiredRoot = model.root
        model.start(b); try await settle(model)
        try await Task.sleep(for: .milliseconds(700))
        assert(retiredRoot == nil, "previous scan tree is still retained")
        for i in 0..<8 {
            model.start(i.isMultiple(of: 2) ? a : b); try await settle(model)
            assert(model.root?.bytes == (i.isMultiple(of: 2) ? 1000 : 400))
            assert(model.root?.url.path == (i.isMultiple(of: 2) ? a.path : b.path))
        }
        model.kind = .image; try await settle(model); assert(model.display?.bytes == 0)
        model.kind = .all; try await settle(model); assert(model.display?.bytes == 400)
        let stress = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : a
        for _ in 0..<2 {
            model.start(stress)
            let deadline = Date().addingTimeInterval(15)
            while model.busy && model.count < 256 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            assert(model.busy, "stress fixture finished before mid-scan cancellation")
            model.cancelling = true; model.task?.cancel(); try await settle(model)
            assert(model.errors.contains { $0.contains("扫描已取消") })
            model.start(b); try await settle(model)
            assert(model.root?.bytes == 400 && !model.partial && !model.cancelling)
        }
        let metadata = base.appendingPathComponent("snapshots")
        let soakSeconds = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 0) : 0
        let end = Date().addingTimeInterval(soakSeconds)
        var cycles = 0, quotaRefusals = 0
        repeat {
            model.start(a); try await settle(model)
            weak var retiredLeaf = model.root?.children.first
            model.detectDuplicates(); try await settle(model)
            assert(model.duplicateGroups.count == 1)
            model.closeDuplicates(); assert(model.duplicateGroups.isEmpty && !model.showDuplicates)
            let snap = try DiskSnapshot.make(model.root!, count: model.count, warnings: model.errors.count)
            do { try SnapshotStore.save(snap, to: metadata) } catch { quotaRefusals += 1 }
            model.history = try SnapshotStore.load(from: metadata)
            model.showHistory = true
            if let first = model.history.first { model.baselineID = first.id; model.compareSnapshot(first) }
            model.closeHistory(); assert(model.history.isEmpty && model.comparison.isEmpty)
            model.start(b); try await settle(model)
            try await Task.sleep(for: .milliseconds(400))
            assert(retiredLeaf == nil, "old file retained after duplicate/history close and rescan")
            cycles += 1
        } while cycles < 12 || Date() < end
        model.start(a); try await settle(model)
        for _ in 0..<3 {
            model.detectDuplicates(); model.closeDuplicates(); try await settle(model)
            assert(model.duplicateGroups.isEmpty && !model.showDuplicates)
        }
        let kept = try SnapshotStore.load(from: metadata); assert(kept.count <= SnapshotStore.maxCount)
        print("PASS: mixed scan/duplicate/history/release cycles=\(cycles), soak_seconds=\(soakSeconds), quota_refusals=\(quotaRefusals), duplicate cancellation=3, weak old-leaf release")
        print("PASS: model consecutive scans, directory switches, old-tree release, filter restore, two mid-scan cancellations and restarts")
    }
}
