import AppKit
import SpacewiseCore
import SpacewiseFixtures
import Testing

@testable import SpacewiseApp

@MainActor struct TreemapRenderSchedulingTests {
    private let initialSize = CGSize(width: 674, height: 457)
    private let intermediateSize = CGSize(width: 854, height: 577)
    private let latestSize = CGSize(width: 590, height: 650)
    private let scan = PresentationFixtures.storageMap(tailFiles: 400)

    @Test func coldResizeCoalescesAndDiscardsCancelledResultForTheSameKey() async throws {
        let model = scan.treemap(parent: 0)
        let (view, renderer) = try await makeView(model)
        defer { renderer.close() }
        view.setModel(model)
        try await waitUntil { renderer.requests.count >= 1 }

        view.setFrameSize(intermediateSize)
        view.setFrameSize(latestSize)
        view.setFrameSize(initialSize)
        renderer.finish(0)
        try await waitUntil { renderer.requests.count >= 2 }
        #expect(renderer.peakActive == 1)
        #expect(renderer.cancelled == [true])
        #expect(renderer.requests.map(\.size) == [initialSize, initialSize])
        #expect(view.mapLayout == nil)

        renderer.finish(1)
        try await waitUntil { view.mapLayout != nil }
        #expect(view.mapLayout?.bounds.size == initialSize)
    }

    @Test func warmResizeUsesDisplayedGeometryAndQueuesLatestModelAndAppearance() async throws {
        let model = scan.treemap(parent: 0)
        let replacement = scan.treemap(parent: model.tiles[1].nodeID)
        let (view, renderer) = try await makeView(model)
        defer { renderer.close() }
        view.setModel(model)
        try await waitUntil { renderer.requests.count >= 1 }
        renderer.finish(0)
        try await waitUntil { view.mapLayout != nil }

        let points = [CGPoint(x: 120, y: 170), CGPoint(x: 395, y: 290), CGPoint(x: 470, y: 180)]
        let originalTargets = points.map { view.tile(atPoint: $0) }
        #expect(originalTargets.allSatisfy { $0 != nil })
        view.setFrameSize(intermediateSize)
        view.appearance = NSAppearance(named: .darkAqua)
        try await waitUntil { renderer.requests.count >= 2 }
        #expect(renderer.requests[1].size == intermediateSize)
        #expect(renderer.requests[1].dark)
        #expect(view.mapLayout?.bounds.size == initialSize)
        let stretched = points.map {
            CGPoint(
                x: $0.x * intermediateSize.width / initialSize.width,
                y: $0.y * intermediateSize.height / initialSize.height)
        }
        #expect(stretched.map { view.tile(atPoint: $0) } == originalTargets)

        // Queue a model and several geometry changes while the cancelled renderer remains gated.
        view.setModel(replacement)
        view.setFrameSize(initialSize)
        view.setFrameSize(latestSize)
        view.appearance = NSAppearance(named: .aqua)
        renderer.finish(1)
        try await waitUntil { renderer.requests.count >= 3 }
        #expect(renderer.peakActive == 1)
        #expect(renderer.cancelled == [false, true])
        #expect(renderer.requests.map(\.size) == [initialSize, intermediateSize, latestSize])
        #expect(renderer.requests[2].scope == replacement.scope)
        #expect(!renderer.requests[2].dark)
        #expect(view.mapLayout == nil)
        #expect(view.tile(atPoint: points[0]) == nil)

        renderer.finish(2)
        try await waitUntil { view.mapLayout != nil }
        let expected = TreemapLayout.compute(replacement, in: CGRect(origin: .zero, size: latestSize))
        #expect(view.mapLayout?.rects == expected.rects)
    }

    private func makeView(_ model: TreemapModel) async throws -> (TreemapView, GatedTreemapRenderer) {
        _ = NSApplication.shared
        let sample = await TreemapRenderer.render(
            model: model, size: CGSize(width: 16, height: 16), scale: 1, dark: false)
        let renderer = GatedTreemapRenderer(image: try #require(sample?.image))
        let view = TreemapView(frame: CGRect(origin: .zero, size: initialSize)) { model, size, _, dark, _ in
            await renderer.render(model: model, size: size, dark: dark)
        }
        view.appearance = NSAppearance(named: .aqua)
        return (view, renderer)
    }

    private func waitUntil(_ ready: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(ready(), sourceLocation: sourceLocation)
    }
}

/// Holds each render at completion and deliberately returns its result even if the caller cancelled it.
@MainActor private final class GatedTreemapRenderer {
    struct Request {
        let size: CGSize
        let scope: Int?
        let dark: Bool
    }
    private let image: CGImage
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var active = 0
    private var closed = false
    private(set) var requests: [Request] = []
    private(set) var cancelled: [Bool] = []
    private(set) var peakActive = 0

    init(image: CGImage) { self.image = image }

    func render(model: TreemapModel, size: CGSize, dark: Bool) async -> RenderedMap? {
        guard !closed else { return nil }
        let index = requests.count
        requests.append(Request(size: size, scope: model.scope, dark: dark))
        active += 1
        peakActive = max(peakActive, active)
        defer { active -= 1 }
        await withCheckedContinuation { gates[index] = $0 }
        cancelled.append(Task.isCancelled)
        let layout = TreemapLayout.compute(model, in: CGRect(origin: .zero, size: size))
        return RenderedMap(layout: layout, image: image)
    }

    func finish(_ index: Int) { gates.removeValue(forKey: index)?.resume() }

    func close() {
        closed = true
        for gate in gates.values { gate.resume() }
        gates.removeAll()
    }
}
