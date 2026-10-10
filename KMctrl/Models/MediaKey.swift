import Foundation

/// A media/aux key as carried in an `NSEvent` of type `.systemDefined`, subtype 8
/// (NX_SUBTYPE_AUX_CONTROL_BUTTONS). `data1` packs the key type, press state and repeat bit.
struct MediaKey: Equatable {
    /// NX_KEYTYPE_*: 0 soundUp, 1 soundDown, 2 brightnessUp, 3 brightnessDown, 7 mute,
    /// 16 play/pause, 17 next, 18 previous, 19 fast, 20 rewind, 21/22 keyboard illumination.
    let key: Int
    let isDown: Bool
    let isRepeat: Bool

    static let subtypeAuxControl = 8
    /// Keys we forward. Power (10), eject (6), caps lock etc. are deliberately excluded.
    static let forwarded: Set<Int> = [0, 1, 2, 3, 7, 16, 17, 18, 19, 20, 21, 22]

    static func decode(data1: Int) -> MediaKey? {
        let state = (data1 >> 8) & 0xFF
        guard state == 0x0A || state == 0x0B else { return nil }
        return MediaKey(key: (data1 >> 16) & 0xFFFF, isDown: state == 0x0A, isRepeat: data1 & 1 == 1)
    }

    var data1: Int { (key << 16) | ((isDown ? 0x0A : 0x0B) << 8) | (isRepeat ? 1 : 0) }
}
