#if canImport(CoreGraphics)
import Foundation
import CoreGraphics
import CoreText
#if canImport(AppKit)
import AppKit
#endif

/// Rendering helpers that turn text and images into a `MonoBitmap` using
/// CoreGraphics/CoreText. Kept separate so the wire protocol stays dependency-free.
public enum OLEDGraphics {

    /// Render into a 128×40 1-bit bitmap via a grayscale CG context + threshold.
    private static func render(threshold: UInt8 = 128, _ draw: (CGContext) -> Void) -> MonoBitmap {
        let w = MonoBitmap.width, h = MonoBitmap.height
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return MonoBitmap()
        }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(ctx)
        guard let data = ctx.data else { return MonoBitmap() }
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h)
        var bmp = MonoBitmap()
        // A CGBitmapContext stores rows top-to-bottom in memory (row 0 = top of
        // the image), which already matches MonoBitmap's top-left origin — so we
        // read straight through with no vertical flip.
        for y in 0..<h {
            for x in 0..<w {
                let v = ptr[y * w + x]
                bmp.set(x, y, v >= threshold)
            }
        }
        return bmp
    }

    /// Render one or two centered lines of text at a chosen point size.
    public static func text(_ lines: [String], fontSize: CGFloat = 16, fontName: String = "Helvetica-Bold") -> MonoBitmap {
        render { ctx in
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            let n = max(1, lines.count)
            let lineH = MonoBitmap.height / n
            for (i, line) in lines.enumerated() {
                let attr: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: CGColor(gray: 1, alpha: 1),
                ]
                let astr = NSAttributedString(string: line, attributes: attr)
                let ctLine = CTLineCreateWithAttributedString(astr as CFAttributedString)
                let bounds = CTLineGetImageBounds(ctLine, ctx)
                let x = (CGFloat(MonoBitmap.width) - bounds.width) / 2 - bounds.origin.x
                // Row i from the top → CG y from the bottom.
                let rowTop = CGFloat(MonoBitmap.height - (i + 1) * lineH)
                let y = rowTop + (CGFloat(lineH) - bounds.height) / 2 - bounds.origin.y
                ctx.textPosition = CGPoint(x: max(0, x), y: max(0, y))
                CTLineDraw(ctLine, ctx)
            }
        }
    }

    public static func text(_ line: String, fontSize: CGFloat = 22) -> MonoBitmap {
        text([line], fontSize: fontSize)
    }

    #if canImport(AppKit)
    /// Load an image file and fit it (aspect-preserving) into the 128×40 screen.
    public static func image(contentsOf url: URL, threshold: UInt8 = 128) -> MonoBitmap? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: MonoBitmap.width, height: MonoBitmap.height)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return image(cg, threshold: threshold)
    }
    #endif

    /// Fit a CGImage into 128×40, preserving aspect ratio, centered.
    public static func image(_ cg: CGImage, threshold: UInt8 = 128) -> MonoBitmap {
        render(threshold: threshold) { ctx in
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let scale = min(CGFloat(MonoBitmap.width) / iw, CGFloat(MonoBitmap.height) / ih)
            let dw = iw * scale, dh = ih * scale
            let dx = (CGFloat(MonoBitmap.width) - dw) / 2
            let dy = (CGFloat(MonoBitmap.height) - dh) / 2
            ctx.draw(cg, in: CGRect(x: dx, y: dy, width: dw, height: dh))
        }
    }
}
#endif
