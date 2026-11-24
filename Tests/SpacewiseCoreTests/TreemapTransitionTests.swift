import CoreGraphics
import Foundation
import SpacewiseFixtures
import Testing

@testable import SpacewiseCore

@Suite struct TreemapTransitionTests {
    private let result = PresentationFixtures.storageMap(tailFiles: 400)
    private let bounds = CGRect(x: 0, y: 0, width: 900, height: 500)
    private func node(_ name: String) throws -> Int { try #require(result.nodes.first { $0.name == name }?.id) }
    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6
            && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
    }

    @Test func drillingIntoAFolderGrowsItsRectangleToFillTheMap() throws {
        let top = result.treemap(parent: 0)
        let users = try node("Users")
        let inside = result.treemap(parent: users)
        let topLayout = TreemapLayout.compute(top, in: bounds)
        let insideLayout = TreemapLayout.compute(inside, in: bounds)
        let tile = try #require(top.tileIndex(forNode: users))
        let transition = TreemapTransition.between(
            old: top, topLayout, new: inside, insideLayout, sameModel: false,
            reduceMotion: false)
        #expect(transition == .zoomIn(from: topLayout.rects[tile]))
        let geometry = transition.geometry(in: bounds)
        #expect(geometry.incomingStart == topLayout.rects[tile] && geometry.incomingEnd == bounds)
        #expect(geometry.outgoingStart == bounds && geometry.incomingOnTop)
        // At the end the old picture is enlarged so the folder's old rectangle covers exactly the map.
        let folder = topLayout.rects[tile]
        let end = geometry.outgoingEnd
        let sx = end.width / bounds.width
        let sy = end.height / bounds.height
        let mapped = CGRect(
            x: end.minX + folder.minX * sx, y: end.minY + folder.minY * sy,
            width: folder.width * sx, height: folder.height * sy)
        #expect(near(mapped, bounds))
    }

    @Test func zoomingOutShrinksTheOldMapIntoItsFolder() throws {
        let users = try node("Users")
        let inside = result.treemap(parent: users)
        let top = result.treemap(parent: 0)
        let insideLayout = TreemapLayout.compute(inside, in: bounds)
        let topLayout = TreemapLayout.compute(top, in: bounds)
        let tile = try #require(top.tileIndex(forNode: users))
        let transition = TreemapTransition.between(
            old: inside, insideLayout, new: top, topLayout, sameModel: false,
            reduceMotion: false)
        #expect(transition == .zoomOut(to: topLayout.rects[tile]))
        let geometry = transition.geometry(in: bounds)
        #expect(geometry.outgoingStart == bounds && geometry.outgoingEnd == topLayout.rects[tile])
        #expect(geometry.incomingEnd == bounds && !geometry.incomingOnTop)
        #expect(near(geometry.incomingStart, TreemapTransition.enlarged(bounds, toFill: topLayout.rects[tile])))
        // The reverse of the zoom in: same rectangles, swapped roles.
        let zoomIn = TreemapTransition.zoomIn(from: topLayout.rects[tile]).geometry(in: bounds)
        #expect(near(zoomIn.outgoingEnd, geometry.incomingStart) && zoomIn.incomingStart == geometry.outgoingEnd)
    }

    @Test func reduceMotionSameScopeAndUntraceableZoomsDoNotMove() throws {
        let top = result.treemap(parent: 0)
        let users = try node("Users")
        let inside = result.treemap(parent: users)
        let topLayout = TreemapLayout.compute(top, in: bounds)
        let insideLayout = TreemapLayout.compute(inside, in: bounds)
        #expect(
            TreemapTransition.between(
                old: top, topLayout, new: inside, insideLayout, sameModel: false,
                reduceMotion: true) == .crossFade)
        // New data for the same place (a live checkpoint) fades; a resize of the same model cuts.
        #expect(
            TreemapTransition.between(
                old: top, topLayout, new: top, topLayout, sameModel: false,
                reduceMotion: false) == .crossFade)
        #expect(
            TreemapTransition.between(
                old: top, topLayout, new: top, topLayout, sameModel: true,
                reduceMotion: false) == .cut)
        // A folder that is not drawn in either map (picked in the list, say) cannot be traced: fade.
        let caches = try node("Caches")
        let music = try node("Music")
        let a = result.treemap(parent: caches)
        let b = result.treemap(parent: music)
        #expect(
            TreemapTransition.between(
                old: a, TreemapLayout.compute(a, in: bounds), new: b,
                TreemapLayout.compute(b, in: bounds), sameModel: false,
                reduceMotion: false) == .crossFade)
        for still in [TreemapTransition.crossFade, .cut] {
            let geometry = still.geometry(in: bounds)
            #expect(geometry.frame(at: 0.5).outgoing == bounds && geometry.frame(at: 0.5).incoming == bounds)
        }
    }

    @Test func framesInterpolateBetweenTheEndsAndFadeTheTopPicture() {
        let folder = CGRect(x: 100, y: 50, width: 200, height: 100)
        let geometry = TreemapTransition.zoomIn(from: folder).geometry(in: bounds)
        #expect(geometry.frame(at: 0).incoming == folder && geometry.frame(at: 0).topOpacity == 0)
        #expect(geometry.frame(at: 1).incoming == bounds && geometry.frame(at: 1).topOpacity == 1)
        #expect(geometry.frame(at: 2) == geometry.frame(at: 1))  // clamped
        let half = geometry.frame(at: 0.5).incoming
        #expect(half.minX == 50 && half.width == 550)
        let out = TreemapTransition.zoomOut(to: folder).geometry(in: bounds)
        #expect(out.frame(at: 0).topOpacity == 1 && out.frame(at: 1).topOpacity == 0)
    }

    @Test func theEaseCurveStartsAndEndsGentlyAndIsMonotonic() {
        #expect(TreemapTransition.eased(0) == 0 && abs(TreemapTransition.eased(1) - 1) < 1e-9)
        #expect(abs(TreemapTransition.eased(0.5) - 0.5) < 1e-6)
        #expect(TreemapTransition.eased(0.1) < 0.1 && TreemapTransition.eased(0.9) > 0.9)
        var previous = 0.0
        for step in 1...100 {
            let value = TreemapTransition.eased(Double(step) / 100)
            #expect(value >= previous)
            previous = value
        }
        #expect(TreemapTransition.zoomIn(from: .zero).duration == 0.25 && TreemapTransition.cut.duration == 0)
    }
}
