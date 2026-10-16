import Foundation
import XCTest

/// Reads the captured CLI output in `Fixtures/`.
///
/// Every file there came off a real run: `screenctx status`, `launchctl
/// print`, `recall … --json`, the collector's launchd plist, and a tail of its
/// log. The three status variants Memory cannot make happen on a live Mac
/// (stopped, no store, no ticks) are written to screenctx's own printing rules
/// and say so in the file.
enum Fixture {

    static func text(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            XCTFail("missing fixture: \(name)", file: file, line: line)
            return ""
        }
        return text
    }

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        Data(text(name, file: file, line: line).utf8)
    }
}
