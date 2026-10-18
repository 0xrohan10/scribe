// Draws Scribe's mark and writes the app's icons from it:
//   App/AppIcon.icon                      the app icon, as a layered Icon Composer document, so macOS 26 draws its own
//                                         shape and glass instead of boxing a flat icon inside a gray tile
//   App/Assets.xcassets/ScribeMark.imageset  the bare mark as a vector template image (menu bar icon, sidebar logo)
// Rerun after changing the mark:
//
//   swift scripts/make-icons.swift
//
// The mark is drawn here rather than taken from SF Symbols, whose license doesn't allow symbols in app icons or logos.

import AppKit

let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")

/// Five rounded bars, tallest in the middle, filling `box`.
func bars(in box: CGRect) -> [CGRect] {
    let heights: [CGFloat] = [0.38, 0.72, 1.0, 0.62, 0.3]
    let width = box.width / CGFloat(heights.count * 2 - 1)
    return heights.enumerated().map { i, h in
        CGRect(x: box.minX + CGFloat(i * 2) * width, y: box.midY - box.height * h / 2, width: width, height: box.height * h)
    }
}

/// The app icon's foreground layer: white bars on a 1024 canvas. The icon document supplies the background.
func markSVG() -> String {
    let rects = bars(in: CGRect(x: 262, y: 282, width: 500, height: 460)).map {
        String(format: #"<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="white"/>"#, $0.minX, $0.minY, $0.width, $0.height, $0.width / 2)
    }
    return #"<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">"# + rects.joined() + "</svg>"
}

/// Ink with a soft top light behind a glass layer of bars.
let iconJSON = """
    {
      "fill" : {
        "linear-gradient" : [
          "srgb:0.24000,0.24000,0.24000,1.00000",
          "srgb:0.05000,0.05000,0.05000,1.00000"
        ]
      },
      "groups" : [
        {
          "layers" : [
            {
              "image-name" : "mark.svg",
              "name" : "mark"
            }
          ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "translucency" : { "enabled" : true, "value" : 0.3 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """

/// The bare mark as a one-page PDF, 18×18 pt with a little air, for template rendering.
func markPDF() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    for bar in bars(in: CGRect(x: 1.5, y: 2, width: 15, height: 14)) {
        context.addPath(CGPath(roundedRect: bar, cornerWidth: bar.width / 2, cornerHeight: bar.width / 2, transform: nil))
    }
    context.fillPath()
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

func write(_ data: Data, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file)
}

let icon = app.appending(path: "AppIcon.icon")
try write(Data(iconJSON.utf8), to: icon.appending(path: "icon.json"))
try write(Data(markSVG().utf8), to: icon.appending(path: "Assets/mark.svg"))

let assets = app.appending(path: "Assets.xcassets")
try write(Data(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#.utf8), to: assets.appending(path: "Contents.json"))
let mark = assets.appending(path: "ScribeMark.imageset")
try write(markPDF(), to: mark.appending(path: "ScribeMark.pdf"))
try write(
    Data(
        #"{ "images" : [ { "filename" : "ScribeMark.pdf", "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 }, "properties" : { "preserves-vector-representation" : true, "template-rendering-intent" : "template" } }"#
            .utf8), to: mark.appending(path: "Contents.json"))

print("Wrote \(icon.path) and \(mark.path)")
