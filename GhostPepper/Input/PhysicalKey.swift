import Carbon.HIToolbox
import Foundation
import CoreGraphics

struct PhysicalKey: Codable, Hashable {
    let keyCode: UInt16

    var displayName: String {
        switch keyCode {
        case 36:
            "Return"
        case 48:
            "Tab"
        case 49:
            "Space"
        case 51:
            "Delete"
        case 53:
            "Escape"
        case 54:
            "Right Command"
        case 55:
            "Left Command"
        case 56:
            "Left Shift"
        case 57:
            "Caps Lock"
        case 58:
            "Left Option"
        case 59:
            "Left Control"
        case 60:
            "Right Shift"
        case 61:
            "Right Option"
        case 62:
            "Right Control"
        case 63:
            "Fn / Globe"
        default:
            Self.letterKeyName(for: keyCode) ?? "Key Code \(keyCode)"
        }
    }

    var sortOrder: Int {
        switch keyCode {
        case 54, 55:
            0
        case 58, 61:
            1
        case 59, 62:
            2
        case 56, 60:
            3
        case 63:
            4
        default:
            100
        }
    }

    var shortcutRecorderDisplayName: String {
        switch keyCode {
        case 54:
            "⌘ʳ"
        case 55:
            "⌘ˡ"
        case 56:
            "⇧ˡ"
        case 58:
            "⌥ˡ"
        case 59:
            "⌃ˡ"
        case 60:
            "⇧ʳ"
        case 61:
            "⌥ʳ"
        case 62:
            "⌃ʳ"
        default:
            displayName
        }
    }

    private static func letterKeyName(for keyCode: UInt16) -> String? {
        if let localizedName = localizedKeyName(for: keyCode) {
            return localizedName
        }

        let letterKeyCodes: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M"
        ]
        return letterKeyCodes[keyCode]
    }

    private static func localizedKeyName(for keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { rawBuffer -> String? in
            guard let layout = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }

            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else {
                return nil
            }

            let string = String(utf16CodeUnits: characters, count: length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !string.isEmpty else {
                return nil
            }

            return string.uppercased(with: .current)
        }
    }
}

extension PhysicalKey {
    var isModifierKey: Bool {
        modifierMaskRawValue != nil
    }

    var modifierMaskRawValue: UInt64? {
        switch keyCode {
        case 54:
            UInt64(NX_DEVICERCMDKEYMASK | NX_COMMANDMASK)
        case 55:
            UInt64(NX_DEVICELCMDKEYMASK | NX_COMMANDMASK)
        case 56:
            UInt64(NX_DEVICELSHIFTKEYMASK | NX_SHIFTMASK)
        case 57:
            CGEventFlags.maskAlphaShift.rawValue
        case 58:
            UInt64(NX_DEVICELALTKEYMASK | NX_ALTERNATEMASK)
        case 59:
            UInt64(NX_DEVICELCTLKEYMASK | NX_CONTROLMASK)
        case 60:
            UInt64(NX_DEVICERSHIFTKEYMASK | NX_SHIFTMASK)
        case 61:
            UInt64(NX_DEVICERALTKEYMASK | NX_ALTERNATEMASK)
        case 62:
            UInt64(NX_DEVICERCTLKEYMASK | NX_CONTROLMASK)
        case 63:
            CGEventFlags.maskSecondaryFn.rawValue
        default:
            nil
        }
    }
}
