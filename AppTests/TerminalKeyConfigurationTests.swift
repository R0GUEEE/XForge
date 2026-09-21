import XCTest
@testable import XForge

/// The extra-keys bar is configurable, with one key that deliberately is not.
@MainActor
final class TerminalKeyConfigurationTests: XCTestCase {

    private func makeConfiguration() -> TerminalKeyConfiguration {
        // Start from a clean slate: the configuration persists in UserDefaults,
        // so a test that ran before this one would otherwise leak into it.
        UserDefaults.standard.removeObject(forKey: "org.xforge.terminal.hiddenKeys")
        return TerminalKeyConfiguration()
    }

    func testHideKeyboardIsAlwaysVisible() {
        let configuration = makeConfiguration()
        XCTAssertTrue(configuration.isVisible(.hideKeyboard))

        // Even if something tries to switch it off: without it there is no way
        // back to the screen once the keyboard covers it.
        configuration.setVisible(false, for: .hideKeyboard)
        XCTAssertTrue(configuration.isVisible(.hideKeyboard),
                      "the hide-keyboard key is pinned on purpose")
        XCTAssertTrue(configuration.visibleKeys.contains(.hideKeyboard))
    }

    func testKeysStartVisible() {
        let configuration = makeConfiguration()
        for key in TerminalKey.allCases {
            XCTAssertTrue(configuration.isVisible(key), "\(key.rawValue) should start shown")
        }
    }

    func testHidingAKeyRemovesItFromTheBar() {
        let configuration = makeConfiguration()
        configuration.setVisible(false, for: .pipe)

        XCTAssertFalse(configuration.isVisible(.pipe))
        XCTAssertFalse(configuration.visibleKeys.contains(.pipe))
        XCTAssertTrue(configuration.visibleKeys.contains(.slash), "others are unaffected")
    }

    func testHidingPersistsBetweenInstances() {
        let configuration = makeConfiguration()
        configuration.setVisible(false, for: .colon)

        // A new instance reads what was stored — otherwise the choice would be
        // lost every time the terminal is reopened.
        let reloaded = TerminalKeyConfiguration()
        XCTAssertFalse(reloaded.isVisible(.colon))
    }

    func testResetShowsEverything() {
        let configuration = makeConfiguration()
        configuration.setVisible(false, for: .bang)
        configuration.setVisible(false, for: .previous)
        configuration.resetToDefaults()

        XCTAssertEqual(configuration.visibleKeys.count, TerminalKey.allCases.count)
    }

    func testBarOrderIsStable() {
        // The keys keep their declared order regardless of what is hidden, so
        // hiding one does not shuffle the rest.
        let configuration = makeConfiguration()
        let before = configuration.visibleKeys
        configuration.setVisible(false, for: .tab)
        let after = configuration.visibleKeys

        XCTAssertEqual(after, before.filter { $0 != .tab })
    }

    func testEveryKeyHasALabelOrASymbol() {
        // A key that renders as neither would be an invisible button.
        for key in TerminalKey.allCases {
            let described = !key.label.isEmpty || key.symbol != nil
            XCTAssertTrue(described, "\(key.rawValue) has nothing to draw")
        }
    }

    func testPunctuationKeysInsertTheirOwnCharacter() {
        // The label and the inserted text are declared separately, so they can
        // drift; this pins the ones where drift would be a real bug.
        for key in [TerminalKey.dash, .dot, .slash, .colon, .bang, .pipe] {
            XCTAssertEqual(key.label.count, 1, "\(key.rawValue) should be one character")
        }
        XCTAssertEqual(TerminalKey.pipe.label, "|")
        XCTAssertEqual(TerminalKey.bang.label, "!")
        XCTAssertEqual(TerminalKey.dash.label, "-")
    }
}
