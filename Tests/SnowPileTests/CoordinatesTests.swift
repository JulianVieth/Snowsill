import CoreGraphics
import Testing
@testable import SnowPileCore

@Suite struct CoordinatesTests {
    let mainHeight: CGFloat = 1000

    @Test func mainScreenFrameMapsToItself() {
        let main = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        #expect(Coordinates.cgRect(fromAppKit: main, mainScreenHeight: mainHeight) == main)
    }

    @Test func windowNearTopOfMainScreen() {
        // AppKit: 100 pt hoch, Oberkante 50 pt unter dem oberen Rand
        let appKit = CGRect(x: 10, y: 850, width: 200, height: 100)
        let cg = Coordinates.cgRect(fromAppKit: appKit, mainScreenHeight: mainHeight)
        #expect(cg == CGRect(x: 10, y: 50, width: 200, height: 100))
    }

    @Test func screenAboveMainScreenHasNegativeCGY() {
        let above = CGRect(x: 0, y: 1000, width: 1920, height: 1080)
        let cg = Coordinates.cgRect(fromAppKit: above, mainScreenHeight: mainHeight)
        #expect(cg == CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    @Test func screenLeftAndBelowMainScreen() {
        let left = CGRect(x: -1280, y: -300, width: 1280, height: 800)
        let cg = Coordinates.cgRect(fromAppKit: left, mainScreenHeight: mainHeight)
        #expect(cg == CGRect(x: -1280, y: 500, width: 1280, height: 800))
    }

    @Test func conversionIsReversible() {
        let rects = [
            CGRect(x: 0, y: 0, width: 1600, height: 1000),
            CGRect(x: -1280, y: -300, width: 1280, height: 800),
            CGRect(x: 1600, y: 1000, width: 1920, height: 1080),
        ]
        for rect in rects {
            let cg = Coordinates.cgRect(fromAppKit: rect, mainScreenHeight: mainHeight)
            #expect(Coordinates.appKitRect(fromCG: cg, mainScreenHeight: mainHeight) == rect)
        }
    }

    @Test func sceneLocalOnMainScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        #expect(Coordinates.sceneLocal(CGPoint(x: 0, y: 0), screenFrameCG: screen) == CGPoint(x: 0, y: 1000))
        #expect(Coordinates.sceneLocal(CGPoint(x: 100, y: 1000), screenFrameCG: screen) == CGPoint(x: 100, y: 0))
        #expect(Coordinates.sceneLocal(CGPoint(x: 800, y: 250), screenFrameCG: screen) == CGPoint(x: 800, y: 750))
    }

    @Test func sceneLocalOnOffsetScreen() {
        let screen = CGRect(x: -1280, y: 500, width: 1280, height: 800)
        // Oben links dieses Bildschirms
        #expect(Coordinates.sceneLocal(CGPoint(x: -1280, y: 500), screenFrameCG: screen) == CGPoint(x: 0, y: 800))
        // Unten rechts
        #expect(Coordinates.sceneLocal(CGPoint(x: 0, y: 1300), screenFrameCG: screen) == CGPoint(x: 1280, y: 0))
    }
}
