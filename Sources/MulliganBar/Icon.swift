import SwiftUI
import AppKit

/// Draws the app icon in code, so the build needs no design assets: `MulliganBar --make-icon <dir.iconset>`.
@MainActor
enum IconMaker {
    struct IconView: View {
        let s: CGFloat
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.96), Color(red: 0.25, green: 0.55, blue: 0.98)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: s * 0.82, height: s * 0.82)
                    .shadow(color: .black.opacity(0.25), radius: s * 0.02, y: s * 0.012)
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: s * 0.40, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: s, height: s)
        }
    }

    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                                          ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                                          ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
        for (name, px) in sizes {
            let r = ImageRenderer(content: IconView(s: px))
            r.scale = 1
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        }
    }
}
