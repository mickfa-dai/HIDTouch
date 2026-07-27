import Foundation

/// Minimal assertion harness.
///
/// XCTest and swift-testing both ship with Xcode, not with the Command Line
/// Tools, so a plain executable is what keeps these checks runnable on a
/// machine that only has `swift build`.
enum Check {
    private(set) static var failures: [String] = []
    private(set) static var passed = 0
    private static var currentSuite = ""

    static func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("\n\u{001B}[1m\(name)\u{001B}[0m")
        body()
    }

    static func expect(_ condition: Bool, _ label: String, file: StaticString = #file, line: UInt = #line) {
        if condition {
            passed += 1
            print("  ✓ \(label)")
        } else {
            let message = "\(currentSuite) / \(label)  (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))"
            failures.append(message)
            print("  ✗ \(label)")
        }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String, file: StaticString = #file, line: UInt = #line) {
        if actual == expected {
            passed += 1
            print("  ✓ \(label)")
        } else {
            let message = "\(currentSuite) / \(label): expected \(expected), got \(actual)  (\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line))"
            failures.append(message)
            print("  ✗ \(label): expected \(expected), got \(actual)")
        }
    }

    static func close(_ actual: Double, _ expected: Double, _ accuracy: Double, _ label: String, file: StaticString = #file, line: UInt = #line) {
        if abs(actual - expected) <= accuracy {
            passed += 1
            print("  ✓ \(label)")
        } else {
            let message = String(format: "%@ / %@: expected %.6f ± %.6f, got %.6f  (%@:%d)",
                                 currentSuite, label, expected, accuracy, actual,
                                 URL(fileURLWithPath: "\(file)").lastPathComponent, Int(line))
            failures.append(message)
            print(String(format: "  ✗ %@: expected %.6f ± %.6f, got %.6f", label, expected, accuracy, actual))
        }
    }

    static func summarize() -> Never {
        print("\n" + String(repeating: "-", count: 60))
        if failures.isEmpty {
            print("\u{001B}[32mAll \(passed) checks passed.\u{001B}[0m")
            exit(0)
        }
        print("\u{001B}[31m\(failures.count) failed, \(passed) passed:\u{001B}[0m")
        for f in failures { print("  - \(f)") }
        exit(1)
    }
}
