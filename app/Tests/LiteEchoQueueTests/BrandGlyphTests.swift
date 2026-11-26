import AppKit
import Testing
@testable import LiteEchoQueue

@Suite struct BrandGlyphTests {
    @Test func isMenuBarTemplateImage() {
        for progress in [nil, 0.0, 0.42, 1.0] as [Double?] {
            let image = BrandGlyph.image(progress: progress)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
    }
}
