import Foundation

/// Grows a `LogicalNamespace` incrementally. Owned by the scanner worker (or a one-shot `build`); never shared.
///
/// The physical tree is a set of directories whose children are grouped by name. The unified root is the group
/// container of the System and Data roots; a folder that is real on both volumes becomes another container whose
/// members are those directories. Every child of a member is added to its container's name group exactly once, in
/// ascending id order during a scan (`advance`) or top-down over a settled array (`buildSettled`). Adding a child
/// re-evaluates only its own name group with the same rules the full build used, so total work is linear in the
/// children admitted plus the groups they touch, never in the size of the discovered tree.
///
/// A name group's visible outcome: one entry for a unique name; the real folder for a stub plus a real folder; one
/// merged folder (primary = lowest physical id) for two or more real folders; every real entry for names that
/// cannot merge (files). Hidden entries map to the entry that stands for them. Ids are never renumbered.
///
/// Cancellation is polled per child and per group; a group's outcome is committed whole or not at all, so a
/// cancelled builder is coherent and resumable, and an unfinished group is retried on the next `advance`.
struct NamespaceBuilder {
    private(set) var view = LogicalNamespace()
    /// Nodes [0, fed) have been offered to the builder (lazy mode).
    private(set) var fed = 0
    /// Receives the builder's work (children admitted, groups re-evaluated, aggregate settles). Nil outside tests, so
    /// a scan counts nothing.
    var observer: (any ProgressiveIndexObserver)?

    struct Environment {
        let nodes: [ScanNode]
        let cancelled: () -> Bool
        /// Current bytes of a physical root, used when it joins the managed group.
        let bytes: (Int) -> (logical: UInt64, allocated: UInt64)
        /// Physical children of a node with id below `limit`, in the order they should be admitted.
        let children: (Int, Int) -> [Int]
    }
    enum Advance { case done, cancelled, rebuild }

    private struct GroupKey: Hashable {
        let container: Int
        let name: String
    }
    private struct Group {
        var first: Int
        var rest: [Int] = []
        var out: Int
        var outMore: [Int] = []
        var primary = -1
        var slot: Int
        var managedList: Bool
        var ids: [Int] { [first] + rest }
        var outputs: [Int] { [out] + outMore }
    }
    private struct Pending {
        var member: Int
        var container: Int
        var limit: Int
        var ids: [Int]?
        var next = 0
    }
    private struct Outcome {
        var visible: [Int]
        var primary = -1
        var members: [Int] = []
        var hidden: [(id: Int, target: Int)] = []
    }
    private static let rootContainer = -1

    private var eager = false
    private var groups: [GroupKey: Group] = [:]
    /// Physical directory → the logical container its children are grouped into (-1 = the unified root).
    private var containerOf: [Int: Int] = [:]
    private var pending: [Pending] = []
    private var retry = Set<GroupKey>()
    private var dirty = Set<Int>()
    private var knownRoots: [Int: String] = [:]
    private var shownAuxiliary = Set<Int>()
    private var aggregateSettled = false

    // MARK: Public operations

    /// Mark an already-admitted node whose metadata changed (for example its issue) so its name group is re-evaluated.
    mutating func entryChanged(_ id: Int) { if id < fed { dirty.insert(id) } }

    /// Apply a signed byte delta when `id` is one of the managed group's physical roots.
    mutating func attribute(_ id: Int, logical: UInt64, allocated: UInt64, subtract: Bool) {
        guard view.managedPhysicalRoots.contains(id) else { return }
        aggregateSettled = false
        if subtract {
            Self.subtract(&view.managedAggregate, logical, allocated)
        } else {
            view.managedAggregate.logicalBytes += logical
            view.managedAggregate.allocatedBytes += allocated
        }
    }

    /// Recompute the managed aggregate once from finalized nodes, replacing the conservative progressive value.
    mutating func settleAggregate(nodes: [ScanNode]) {
        guard !aggregateSettled else { return }
        var total = MeasuredCategory()
        for id in view.managedPhysicalRoots where nodes.indices.contains(id) {
            total.logicalBytes += nodes[id].logicalBytes
            total.allocatedBytes += nodes[id].allocatedBytes
            total.allocationUnknown = total.allocationUnknown || nodes[id].allocationUnknown || nodes[id].issue != nil
        }
        view.managedAggregate = total
        aggregateSettled = true
        observer?.indexDidWork(.namespaceSettle(roots: view.managedPhysicalRoots.count))
    }

    /// Admit every node not yet seen. State stays coherent when cancelled, and a later call resumes.
    mutating func advance(_ env: Environment, rootPaths: [Int: String]) -> Advance {
        for key in retry {
            guard reconcile(key, env) else { return .cancelled }
            retry.remove(key)
        }
        switch syncRoots(env, rootPaths, auxiliary: false) {
        case .rebuild: return .rebuild
        default: break
        }
        guard drain(env) else { return .cancelled }
        guard syncRoots(env, rootPaths, auxiliary: true) == .done else { return .cancelled }
        while fed < env.nodes.count {
            if env.cancelled() { return .cancelled }
            let node = env.nodes[fed]
            if let parent = node.parent, let container = containerOf[parent] {
                let admitted = addChild(node.id, container: container, env)
                fed += 1
                guard admitted, drain(env) else { return .cancelled }
            } else {
                fed += 1
            }
        }
        // An id leaves `dirty` only once its group has been handled (or handed to `retry`), so a cancel part-way
        // through leaves every unprocessed group queued for the next `advance`.
        for id in dirty.sorted() {
            guard let parent = env.nodes[id].parent, let container = containerOf[parent] else {
                dirty.remove(id)
                continue
            }
            let key = GroupKey(container: container, name: env.nodes[id].name)
            guard groups[key] != nil else {
                dirty.remove(id)
                continue
            }
            dirty.remove(id)
            if !reconcile(key, env) {
                retry.insert(key)
                return .cancelled
            }
            guard drain(env) else { return .cancelled }
        }
        return .done
    }

    /// One-shot construction over a settled node array: admits every child top-down instead of by id order.
    mutating func buildSettled(
        nodes: [ScanNode], rootPaths: [Int: String], isCancelled: @escaping () -> Bool,
        children: @escaping (Int) -> [Int]
    ) -> Bool {
        eager = true
        let env = Environment(
            nodes: nodes, cancelled: isCancelled,
            bytes: { (nodes[$0].logicalBytes, nodes[$0].allocatedBytes) },
            children: { parent, _ in children(parent) })
        guard !isCancelled() else { return false }
        guard syncRoots(env, rootPaths, auxiliary: false) == .done, drain(env),
            syncRoots(env, rootPaths, auxiliary: true) == .done
        else { return false }
        fed = nodes.count
        settleAggregate(nodes: nodes)
        return true
    }

    // MARK: Roots

    private mutating func syncRoots(_ env: Environment, _ rootPaths: [Int: String], auxiliary: Bool) -> Advance {
        let roots = rootPaths.sorted { $0.key < $1.key }
        if !auxiliary {
            for (id, path) in roots {
                if let known = knownRoots[id] {
                    if known != path { return .rebuild }
                    continue
                }
                if path == "/", view.systemRoot == nil {
                    admitRoot(id, path, env, system: true)
                } else if path == StartupDrive.dataVolumePath, view.dataRoot == nil {
                    admitRoot(id, path, env, system: false)
                }
            }
            return .done
        }
        guard view.unified else { return .done }
        for (id, path) in roots where !shownAuxiliary.contains(id) && id != view.systemRoot && id != view.dataRoot {
            if env.cancelled() { return .cancelled }
            knownRoots[id] = path
            shownAuxiliary.insert(id)
            view.managedSlots.append(id)
            view.managedSlots.cost += 1
            view.managedSet.insert(id)
            addRoot(id, env)
        }
        return .done
    }

    private mutating func admitRoot(_ id: Int, _ path: String, _ env: Environment, system: Bool) {
        knownRoots[id] = path
        if system {
            view.systemRoot = id
        } else {
            view.dataRoot = id
        }
        view.unified = true
        register(id, container: Self.rootContainer)
    }

    // MARK: Name groups

    private var limit: Int { eager ? Int.max : fed }

    private mutating func register(_ member: Int, container: Int) {
        containerOf[member] = container
        pending.append(Pending(member: member, container: container, limit: limit))
    }

    /// Consume previously discovered children of newly registered members, iteratively and resumably.
    private mutating func drain(_ env: Environment) -> Bool {
        while var item = pending.popLast() {
            guard containerOf[item.member] == item.container else { continue }
            let ids: [Int]
            if let listed = item.ids {
                ids = listed
            } else {
                ids = env.children(item.member, item.limit)
                item.ids = ids
            }
            while item.next < ids.count {
                if env.cancelled() {
                    pending.append(item)
                    return false
                }
                let child = ids[item.next]
                item.next += 1
                guard addChild(child, container: item.container, env) else {
                    pending.append(item)
                    return false
                }
            }
        }
        return true
    }

    private func isManagedName(_ name: String) -> Bool {
        ScanPolicy().classification(for: "/" + name) == .systemManaged
    }

    /// Admit one child to its name group. False when cancelled while re-evaluating the group: the child is recorded
    /// and its group is retried by the next `advance`, so nothing is lost or half-applied.
    private mutating func addChild(_ id: Int, container: Int, _ env: Environment) -> Bool {
        observer?.indexDidWork(.namespaceVisit)
        let name = env.nodes[id].name
        let key = GroupKey(container: container, name: name)
        if let index = groups.index(forKey: key) {
            groups.values[index].rest.append(id)
            guard reconcile(key, env) else {
                retry.insert(key)
                return false
            }
            return true
        }
        let managedList = container == Self.rootContainer && isManagedName(name)
        let slot: Int
        if container == Self.rootContainer {
            if managedList {
                slot = view.managedSlots.append(id)
                view.managedSlots.cost += 1
            } else {
                slot = view.topSlots.append(id)
                view.topSlots.cost += 1
            }
        } else {
            let list = mergedList(of: container)
            slot = view.merged.values[list].append(id)
            view.merged.values[list].cost += 1
        }
        groups[key] = Group(first: id, out: id, slot: slot, managedList: managedList)
        if managedList {
            view.managedSet.insert(id)
            addRoot(id, env)
        }
        return true
    }

    private func rank(of parent: Int?, container: Int) -> Int {
        guard let parent else { return Int.max }
        if container == Self.rootContainer {
            return parent == view.systemRoot ? 0 : (parent == view.dataRoot ? 1 : 2)
        }
        return view.members[container]?.firstIndex(of: parent) ?? Int.max
    }

    private func evaluate(_ unordered: [Int], container: Int, _ env: Environment) -> Outcome? {
        guard unordered.count > 1 else { return Outcome(visible: unordered) }
        // Member order, then id: the order the full build produced by walking the members in turn.
        let ids = unordered.sorted { a, b in
            let left = rank(of: env.nodes[a].parent, container: container)
            let right = rank(of: env.nodes[b].parent, container: container)
            return left != right ? left < right : a < b
        }
        var real: [Int] = []
        var folders: [Int] = []
        for id in ids {
            if env.cancelled() { return nil }
            let node = env.nodes[id]
            guard !LogicalNamespace.isStub(node) else { continue }
            real.append(id)
            if node.kind == .directory { folders.append(id) }
        }
        var outcome = Outcome(visible: [])
        if folders.count >= 2 && folders.count == real.count {
            guard let primary = folders.min() else {
                preconditionFailure("NamespaceBuilder: a merge needs at least two real folders, found \(folders.count)")
            }
            outcome.visible = [primary]
            outcome.primary = primary
            outcome.members = folders
            for id in ids where id != primary { outcome.hidden.append((id, primary)) }
        } else if real.count == 1 {
            outcome.visible = [real[0]]
            for id in ids where id != real[0] { outcome.hidden.append((id, real[0])) }
        } else if real.isEmpty {
            outcome.visible = [ids[0]]
            for id in ids.dropFirst() { outcome.hidden.append((id, ids[0])) }
        } else {
            // Several real entries that cannot be merged (for example files sharing a name): all stay visible.
            outcome.visible = real
            for id in ids where LogicalNamespace.isStub(env.nodes[id]) { outcome.hidden.append((id, real[0])) }
        }
        return outcome
    }

    /// The position of a merged folder's child list. Every container other than the unified root is a merged folder
    /// with a list: `reconcile` creates the list before it registers members under that folder, and `dismantle`
    /// removes the list and the registrations together. Returned as a position so callers mutate the list in place.
    private func mergedList(of container: Int) -> Dictionary<Int, SlotList>.Index {
        guard let index = view.merged.index(forKey: container) else {
            preconditionFailure(
                "NamespaceBuilder: container \(container) has members but no merged child list "
                    + "(\(view.merged.count) merged folders known)")
        }
        return index
    }

    private func physicalRoots(of visible: [Int]) -> [Int] { visible.flatMap { view.members[$0] ?? [$0] } }
    private func weighCost(of visible: [Int]) -> Int { visible.reduce(0) { $0 + max(1, view.members[$1]?.count ?? 1) } }

    /// Re-evaluate one name group and apply the difference. Returns false when cancelled before anything changed.
    private mutating func reconcile(_ key: GroupKey, _ env: Environment) -> Bool {
        guard var group = groups[key] else { return true }
        guard let outcome = evaluate(group.ids, container: key.container, env) else { return false }
        observer?.indexDidWork(.namespaceReconcile)
        let ids = group.ids
        let oldOut = group.outputs
        let oldPrimary = group.primary
        let rootsBefore = group.managedList ? physicalRoots(of: oldOut) : []
        let costBefore = weighCost(of: oldOut)

        for id in ids { view.hidden[id] = nil }
        for entry in outcome.hidden { view.hidden[entry.id] = entry.target }

        let oldMembers = Set(view.members[oldPrimary] ?? [])
        if outcome.primary >= 0, outcome.primary == oldPrimary, oldMembers.isSubset(of: outcome.members) {
            view.members[oldPrimary] = outcome.members
            for member in outcome.members.reversed() where !oldMembers.contains(member) {
                register(member, container: oldPrimary)
            }
        } else {
            if oldPrimary >= 0 { dismantle(oldPrimary, env) }
            if outcome.primary >= 0 {
                view.members[outcome.primary] = outcome.members
                view.merged[outcome.primary] = SlotList()
                for member in outcome.members.reversed() { register(member, container: outcome.primary) }
            }
        }

        group.out = outcome.visible[0]
        group.outMore = Array(outcome.visible.dropFirst())
        group.primary = outcome.primary
        let costDelta = weighCost(of: outcome.visible) - costBefore
        if key.container == Self.rootContainer {
            if group.managedList {
                if oldOut != outcome.visible { view.managedSlots.set(slot: group.slot, outcome.visible) }
                view.managedSlots.cost += costDelta
            } else {
                if oldOut != outcome.visible { view.topSlots.set(slot: group.slot, outcome.visible) }
                view.topSlots.cost += costDelta
            }
        } else {
            let list = mergedList(of: key.container)
            if oldOut != outcome.visible { view.merged.values[list].set(slot: group.slot, outcome.visible) }
            view.merged.values[list].cost += costDelta
        }
        if group.managedList {
            for entry in oldOut where !outcome.visible.contains(entry) { view.managedSet.remove(entry) }
            for entry in outcome.visible { view.managedSet.insert(entry) }
            let after = physicalRoots(of: outcome.visible)
            let afterSet = Set(after)
            let beforeSet = Set(rootsBefore)
            for root in rootsBefore where !afterSet.contains(root) { removeRoot(root, env) }
            for root in after where !beforeSet.contains(root) { addRoot(root, env) }
        }
        groups[key] = group
        return true
    }

    /// Remove a merged folder's container and everything grouped inside it (iteratively). The caller re-creates it
    /// when the group is still merged.
    private mutating func dismantle(_ primary: Int, _ env: Environment) {
        var stack = [primary]
        var removed = Set<Int>()
        defer { if !removed.isEmpty { pending.removeAll { removed.contains($0.container) } } }
        while let current = stack.popLast() {
            guard let list = view.merged.removeValue(forKey: current) else { continue }
            removed.insert(current)
            for member in view.members.removeValue(forKey: current) ?? [] where containerOf[member] == current {
                containerOf[member] = nil
            }
            for slot in 0..<list.slotCount {
                let key = GroupKey(container: current, name: env.nodes[list.heads[slot]].name)
                guard let group = groups.removeValue(forKey: key) else { continue }
                for id in group.ids { view.hidden[id] = nil }
                if group.primary >= 0 { stack.append(group.primary) }
            }
        }
    }

    // MARK: Managed aggregate membership

    private mutating func addRoot(_ id: Int, _ env: Environment) {
        guard view.managedPhysicalRoots.insert(id).inserted else { return }
        aggregateSettled = false
        let value = env.bytes(id)
        view.managedAggregate.logicalBytes += value.logical
        view.managedAggregate.allocatedBytes += value.allocated
    }
    private mutating func removeRoot(_ id: Int, _ env: Environment) {
        guard view.managedPhysicalRoots.remove(id) != nil else { return }
        aggregateSettled = false
        let value = env.bytes(id)
        Self.subtract(&view.managedAggregate, value.logical, value.allocated)
    }
    private static func subtract(_ aggregate: inout MeasuredCategory, _ logical: UInt64, _ allocated: UInt64) {
        aggregate.logicalBytes = aggregate.logicalBytes >= logical ? aggregate.logicalBytes - logical : 0
        aggregate.allocatedBytes = aggregate.allocatedBytes >= allocated ? aggregate.allocatedBytes - allocated : 0
    }

    /// While scanning, totals are lower bounds and some contents are unread: unknown until settled.
    init(observer: (any ProgressiveIndexObserver)? = nil) {
        self.observer = observer
        view.managedAggregate.allocationUnknown = true
    }
}
