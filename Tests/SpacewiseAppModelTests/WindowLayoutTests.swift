import CoreGraphics
import SpacewiseAppModel
import Testing

@Suite struct WindowLayoutTests {
    @Test func aFirstLaunchIsCentredAtTheDefaultSize() {
        #expect(WindowLayout.initialFrame(savedFrame: nil) == .centered(contentSize: CGSize(width: 1260, height: 800)))
    }

    @Test func aSavedFrameIsRestoredByName() {
        let saved = "398 384 1260 800 0 0 2056 1290 "
        #expect(WindowLayout.initialFrame(savedFrame: saved) == .restoreSaved(name: "SpacewiseMain"))
    }

    @Test func aValueThatIsNotAFrameStartsCentredAtTheDefaultSize() {
        let centred = WindowLayout.InitialFrame.centered(contentSize: WindowLayout.defaultContentSize)
        for damaged: Any in [
            "", "garbage", "10 20 30", "10 20 0 800 0 0 2056 1290", "10 20 -5 800", "1 2 nan 4", 42,
            ["398", "384", "1260", "800"],
        ] {
            #expect(WindowLayout.initialFrame(savedFrame: damaged) == centred, "\(damaged)")
        }
    }

    @Test func theSavedFrameIsReadAsXYWidthHeight() {
        #expect(
            WindowLayout.savedFrameRect("398 384 1260 800 0 0 2056 1290 ")
                == CGRect(x: 398, y: 384, width: 1260, height: 800))
        #expect(WindowLayout.savedFrameRect("-20.5 0 900 560") == CGRect(x: -20.5, y: 0, width: 900, height: 560))
    }

    @Test func theSavedFrameKeyIsTheOneAppKitWrites() {
        #expect(WindowLayout.savedFrameKey == "NSWindow Frame SpacewiseMain")
    }

    @Test func theSizesNestInsideEachOther() {
        let content = WindowLayout.minimumContentSize
        let minimum = WindowLayout.minimumSize
        let standard = WindowLayout.defaultContentSize
        #expect(content.width < minimum.width && content.height < minimum.height)
        #expect(minimum.width < standard.width && minimum.height < standard.height)
        #expect(WindowLayout.compactHeight > minimum.height && WindowLayout.compactHeight < standard.height)
        #expect(WindowLayout.inspectorWidth > minimum.width && WindowLayout.inspectorWidth < standard.width)
    }
}
