"""Render Rumi's native SwiftUI feature glyphs for its README on macOS.

The translation orb is compiled directly from the app source. Other glyphs use
the same SF Symbols as PDFImportCard, ContentView and SettingsView. These small
UI illustrations document Rumi; they are not installation acceptance captures.
"""

import subprocess
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
DESTINATION = PROJECT / "docs/rumi/images"

RENDERER = r'''
// Only the accessibility-format helper is needed by TranslationAction here.
enum L10n {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: key, arguments: arguments)
    }
}

@main
struct ExportReadmeAssets {
    @MainActor static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, symbol) in [("import", "doc.badge.plus"),
                               ("compare", "doc.on.doc"),
                               ("service", "network")] {
            let view = Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(red: 0.35, green: 0.50, blue: 0.93))
                .frame(width: 64, height: 64)
            try save(view, to: destination.appendingPathComponent("native-\(name).png"))
        }
        try save(TranslationOrb(size: 44, isProcessing: false, progress: 0)
            .environment(\.colorScheme, .dark)
            .frame(width: 64, height: 64),
            to: destination.appendingPathComponent("native-translate.png"))
    }

    @MainActor static func save<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.cgImage else {
            fatalError("Could not render \(url.lastPathComponent)")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
        print(url.lastPathComponent)
    }
}
'''


def main():
    source = PROJECT / "macos/Sources/PDFTranslate/TranslationAction.swift"
    DESTINATION.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rumi-readme-") as temporary:
        work = Path(temporary)
        swift = work / "Render.swift"
        swift.write_text("import AppKit\n" + source.read_text() + RENDERER)
        executable = work / "render"
        subprocess.run(
            ["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(executable)],
            check=True,
        )
        subprocess.run([str(executable), str(DESTINATION)], check=True)


if __name__ == "__main__":
    main()
