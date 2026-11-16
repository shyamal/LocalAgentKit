// Synthetic demo fixture only; contains no personal receipt data.
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let context = CGContext(
  data: nil, width: 1000, height: 700, bitsPerComponent: 8,
  bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
let attributes: [NSAttributedString.Key: Any] = [
  .init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 40, nil),
  .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
]
for (index, text) in [
  "LOCAL DEMO CAFE", "2026-11-16", "Coffee and lunch", "Subtotal LKR 1100.00", "Tax LKR 150.50",
  "TOTAL LKR 1250.50",
].enumerated() {
  context.textPosition = CGPoint(x: 60, y: 600 - index * 85)
  CTLineDraw(
    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)),
    context)
}
let data = NSMutableData()
let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
try (data as Data).write(to: output)
