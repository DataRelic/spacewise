/// Virtual key codes the views handle themselves (custom views receive raw keys, not menu actions).
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let space: UInt16 = 49

    static func isReturn(_ code: UInt16) -> Bool { code == returnKey || code == keypadEnter }
}
