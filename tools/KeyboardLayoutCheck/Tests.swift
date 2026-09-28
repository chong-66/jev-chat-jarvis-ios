import XCTest
import UIKit

/// Runs the actual UIKit keyboard views in an isolated simulator host, without
/// Apple credentials, network calls, or relying on iOS to select a keyboard.
@MainActor final class KeyboardLayoutTests: XCTestCase {
    func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testContextSurvivesInputChangesAndControllerRecreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-ui-" + UUID().uuidString)
        let store = JevContextDraftStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        func makeController() -> KeyboardViewController {
            let controller = KeyboardViewController()
            controller.previewContextStore(store)
            controller.loadViewIfNeeded()
            controller.previewPanel("context")
            return controller
        }
        func previewText(_ controller: KeyboardViewController) -> String {
            (descendants(controller.view).first { $0.accessibilityIdentifier == "context.preview" } as? UILabel)?.text ?? ""
        }
        let first = makeController()
        first.previewAppendContext("第一条对话")
        XCTAssertTrue(previewText(first).contains("第一条对话"))
        // Exercise production document-change handling with a supplied ID;
        // this isolated host has no system keyboard input-service connection.
        first.previewDocumentChange(UUID())
        XCTAssertEqual(first.previewContextTurnCount, 1)
        first.previewPanel("context")
        XCTAssertTrue(previewText(first).contains("第一条对话"))
        first.previewAppendContext("第二条对话")
        XCTAssertTrue(previewText(first).contains("第一条对话"))
        XCTAssertTrue(previewText(first).contains("第二条对话"))
        let recreated = makeController()
        XCTAssertTrue(previewText(recreated).contains("第一条对话"))
        XCTAssertTrue(previewText(recreated).contains("第二条对话"))
        let clear = try XCTUnwrap(descendants(recreated.view).first { $0.accessibilityIdentifier == "context.clear" } as? UIButton)
        clear.sendActions(for: .touchUpInside)
        XCTAssertFalse(previewText(makeController()).contains("第一条对话"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL!.path))
    }

    func testCategoriesAndEveryPageAreReachableOnNarrowAndWidePhones() throws {
        for width: CGFloat in [320, 390, 430] {
            let controller = KeyboardViewController()
            let root = UIViewController()
            root.loadViewIfNeeded()
            root.view.frame = CGRect(x: 0, y: 0, width: width, height: 700)
            root.addChild(controller)
            root.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                controller.view.widthAnchor.constraint(equalToConstant: width),
                controller.view.topAnchor.constraint(equalTo: root.view.topAnchor),
                controller.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            ])
            controller.didMove(toParent: root)
            controller.previewPanel("tones")

            func settle() {
                for _ in 0..<3 {
                    root.view.setNeedsLayout()
                    root.view.layoutIfNeeded()
                    controller.view.setNeedsLayout()
                    controller.view.layoutIfNeeded()
                }
            }
            func find(_ id: String) -> UIView? {
                descendants(controller.view).first { $0.accessibilityIdentifier == id }
            }
            func assertVisible(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
                guard let view = find(id) else { XCTFail("Missing \(id) at width \(width)", file: file, line: line); return }
                let frame = view.convert(view.bounds, to: controller.view)
                XCTAssertGreaterThan(frame.width, 10, file: file, line: line)
                XCTAssertGreaterThan(frame.height, 10, file: file, line: line)
                XCTAssertTrue(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                              "Clipped \(id): \(frame) outside \(controller.view.bounds)", file: file, line: line)
            }
            for (index, category) in JevToneCategory.allCases.enumerated() {
                let tabs = try XCTUnwrap(find("tones.categories") as? UISegmentedControl)
                tabs.selectedSegmentIndex = index
                tabs.sendActions(for: .valueChanged)
                settle()
                var seen = Set<String>()
                for _ in 0..<10 {
                    assertVisible("tones.categories")
                    assertVisible("tones.done")
                    let names = descendants(controller.view).compactMap { $0.accessibilityIdentifier }
                        .filter { BUILTIN_TONES[$0] != nil }
                    XCTAssertLessThanOrEqual(names.count, 6)
                    for name in names { assertVisible(name); seen.insert(name) }
                    let next = try XCTUnwrap(find("tones.next") as? UIButton)
                    assertVisible("tones.next")
                    if !next.isEnabled { break }
                    next.sendActions(for: .touchUpInside)
                    settle()
                }
                XCTAssertEqual(seen, Set(category.names(custom: [:])), "Missing presets for \(category)")
            }
            XCTAssertNotNil(find("keyboard.version") as? UILabel)
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
    }
}
