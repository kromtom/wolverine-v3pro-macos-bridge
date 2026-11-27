import Foundation

/// HID identity and report format of a Microsoft Xbox controller connected over Bluetooth
/// (firmware 5.x layout, shared by the Series X|S pad and updated One S pads).
///
/// Input report 1 (16 bytes after the report ID), as parsed by SDL's
/// HIDAPI_DriverXboxOne Bluetooth path:
///   0-1 LX u16, 2-3 LY u16, 4-5 RX u16, 6-7 RY u16 (0..65535, center 32768, Y down positive)
///   8-9 LT u16 (10 bits), 10-11 RT u16 (10 bits)
///   12  hat (low nibble): 0 = centered, 1 = up, then clockwise to 8 = up-left
///   13-14 buttons, 15 bits: A, B, -, X, Y, -, LB, RB, -, -, View, Menu, Guide, LS, RS
///   15  bit 0: Share (Consumer Record)
/// Output report 3 (8 bytes after the report ID): rumble enable mask, 4 magnitudes,
/// duration, start delay, loop count.
public enum XboxBluetooth {
    public static let vendorID: UInt32 = 0x045E

    public static let inputReportID: UInt8 = 0x01
    public static let rumbleReportID: UInt8 = 0x03
    public static let inputReportSize = 17 // including the report ID

    public static let descriptor = Data([
        0x05, 0x01,                    // Usage Page (Generic Desktop)
        0x09, 0x05,                    // Usage (Game Pad)
        0xA1, 0x01,                    // Collection (Application)
        0x85, 0x01,                    //   Report ID (1)

        0x09, 0x01,                    //   Usage (Pointer)
        0xA1, 0x00,                    //   Collection (Physical)
        0x09, 0x30, 0x09, 0x31,        //     Usage (X), Usage (Y)
        0x15, 0x00,                    //     Logical Minimum (0)
        0x27, 0xFF, 0xFF, 0x00, 0x00,  //     Logical Maximum (65535)
        0x95, 0x02, 0x75, 0x10,        //     Report Count (2), Report Size (16)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0xC0,                          //   End Collection

        0x09, 0x01,                    //   Usage (Pointer)
        0xA1, 0x00,                    //   Collection (Physical)
        0x09, 0x32, 0x09, 0x35,        //     Usage (Z), Usage (Rz)
        0x15, 0x00,                    //     Logical Minimum (0)
        0x27, 0xFF, 0xFF, 0x00, 0x00,  //     Logical Maximum (65535)
        0x95, 0x02, 0x75, 0x10,        //     Report Count (2), Report Size (16)
        0x81, 0x02,                    //     Input (Data, Var, Abs)
        0xC0,                          //   End Collection

        0x05, 0x02,                    //   Usage Page (Simulation Controls)
        0x09, 0xC5,                    //   Usage (Brake) = LT
        0x15, 0x00, 0x26, 0xFF, 0x03,  //   Logical Minimum (0), Logical Maximum (1023)
        0x95, 0x01, 0x75, 0x0A,        //   Report Count (1), Report Size (10)
        0x81, 0x02,                    //   Input (Data, Var, Abs)
        0x15, 0x00, 0x25, 0x00,        //   Logical Minimum (0), Logical Maximum (0)
        0x75, 0x06, 0x95, 0x01,        //   Report Size (6), Report Count (1)
        0x81, 0x03,                    //   Input (Const, Var, Abs)

        0x05, 0x02,                    //   Usage Page (Simulation Controls)
        0x09, 0xC4,                    //   Usage (Accelerator) = RT
        0x15, 0x00, 0x26, 0xFF, 0x03,  //   Logical Minimum (0), Logical Maximum (1023)
        0x95, 0x01, 0x75, 0x0A,        //   Report Count (1), Report Size (10)
        0x81, 0x02,                    //   Input (Data, Var, Abs)
        0x15, 0x00, 0x25, 0x00,        //   Logical Minimum (0), Logical Maximum (0)
        0x75, 0x06, 0x95, 0x01,        //   Report Size (6), Report Count (1)
        0x81, 0x03,                    //   Input (Const, Var, Abs)

        0x05, 0x01,                    //   Usage Page (Generic Desktop)
        0x09, 0x39,                    //   Usage (Hat Switch)
        0x15, 0x01, 0x25, 0x08,        //   Logical Minimum (1), Logical Maximum (8)
        0x35, 0x00, 0x46, 0x3B, 0x01,  //   Physical Minimum (0), Physical Maximum (315)
        0x66, 0x14, 0x00,              //   Unit (Degrees)
        0x75, 0x04, 0x95, 0x01,        //   Report Size (4), Report Count (1)
        0x81, 0x42,                    //   Input (Data, Var, Abs, Null State)
        0x75, 0x04, 0x95, 0x01,        //   Report Size (4), Report Count (1)
        0x15, 0x00, 0x25, 0x00,        //   Logical Minimum (0), Logical Maximum (0)
        0x35, 0x00, 0x45, 0x00,        //   Physical Minimum (0), Physical Maximum (0)
        0x65, 0x00,                    //   Unit (None)
        0x81, 0x03,                    //   Input (Const, Var, Abs)

        0x05, 0x09,                    //   Usage Page (Button)
        0x19, 0x01, 0x29, 0x0F,        //   Usage Minimum (1), Usage Maximum (15)
        0x15, 0x00, 0x25, 0x01,        //   Logical Minimum (0), Logical Maximum (1)
        0x75, 0x01, 0x95, 0x0F,        //   Report Size (1), Report Count (15)
        0x81, 0x02,                    //   Input (Data, Var, Abs)
        0x15, 0x00, 0x25, 0x00,        //   Logical Minimum (0), Logical Maximum (0)
        0x75, 0x01, 0x95, 0x01,        //   Report Size (1), Report Count (1)
        0x81, 0x03,                    //   Input (Const, Var, Abs)

        0x05, 0x0C,                    //   Usage Page (Consumer)
        0x0A, 0xB2, 0x00,              //   Usage (Record) = Share
        0x15, 0x00, 0x25, 0x01,        //   Logical Minimum (0), Logical Maximum (1)
        0x95, 0x01, 0x75, 0x01,        //   Report Count (1), Report Size (1)
        0x81, 0x02,                    //   Input (Data, Var, Abs)
        0x15, 0x00, 0x25, 0x00,        //   Logical Minimum (0), Logical Maximum (0)
        0x75, 0x07, 0x95, 0x01,        //   Report Size (7), Report Count (1)
        0x81, 0x03,                    //   Input (Const, Var, Abs)

        0x05, 0x0F,                    //   Usage Page (Physical Interface Device)
        0x09, 0x21,                    //   Usage (Set Effect Report)
        0x85, 0x03,                    //   Report ID (3)
        0xA1, 0x02,                    //   Collection (Logical)
        0x09, 0x97,                    //     Usage (DC Enable Actuators)
        0x15, 0x00, 0x25, 0x01,        //     Logical Minimum (0), Logical Maximum (1)
        0x75, 0x04, 0x95, 0x01,        //     Report Size (4), Report Count (1)
        0x91, 0x02,                    //     Output (Data, Var, Abs)
        0x15, 0x00, 0x25, 0x00,        //     Logical Minimum (0), Logical Maximum (0)
        0x75, 0x04, 0x95, 0x01,        //     Report Size (4), Report Count (1)
        0x91, 0x03,                    //     Output (Const, Var, Abs)
        0x09, 0x70,                    //     Usage (Magnitude)
        0x15, 0x00, 0x25, 0x64,        //     Logical Minimum (0), Logical Maximum (100)
        0x75, 0x08, 0x95, 0x04,        //     Report Size (8), Report Count (4)
        0x91, 0x02,                    //     Output (Data, Var, Abs)
        0x09, 0x50,                    //     Usage (Duration)
        0x66, 0x01, 0x10,              //     Unit (Seconds)
        0x55, 0x0E,                    //     Unit Exponent (-2)
        0x15, 0x00, 0x26, 0xFF, 0x00,  //     Logical Minimum (0), Logical Maximum (255)
        0x75, 0x08, 0x95, 0x01,        //     Report Size (8), Report Count (1)
        0x91, 0x02,                    //     Output (Data, Var, Abs)
        0x09, 0xA7,                    //     Usage (Start Delay)
        0x15, 0x00, 0x26, 0xFF, 0x00,  //     Logical Minimum (0), Logical Maximum (255)
        0x75, 0x08, 0x95, 0x01,        //     Report Size (8), Report Count (1)
        0x91, 0x02,                    //     Output (Data, Var, Abs)
        0x65, 0x00, 0x55, 0x00,        //     Unit (None), Unit Exponent (0)
        0x09, 0x7C,                    //     Usage (Loop Count)
        0x15, 0x00, 0x26, 0xFF, 0x00,  //     Logical Minimum (0), Logical Maximum (255)
        0x75, 0x08, 0x95, 0x01,        //     Report Size (8), Report Count (1)
        0x91, 0x02,                    //     Output (Data, Var, Abs)
        0xC0,                          //   End Collection
        0xC0,                          // End Collection
    ])
}

/// Logical controls of an Xbox pad, independent of any wire format.
public enum Button: Int, CaseIterable, Sendable {
    case a, b, x, y, lb, rb, view, menu, guide, ls, rs, share
    case dpadUp, dpadDown, dpadLeft, dpadRight

    /// Bit index in the 15-bit button field of input report 1; nil for D-pad and Share.
    public var reportBit: Int? {
        switch self {
        case .a: 0
        case .b: 1
        case .x: 3
        case .y: 4
        case .lb: 6
        case .rb: 7
        case .view: 10
        case .menu: 11
        case .guide: 12
        case .ls: 13
        case .rs: 14
        case .share, .dpadUp, .dpadDown, .dpadLeft, .dpadRight: nil
        }
    }
}

/// Controller state in normalized units: sticks -1...1 (up = +1), triggers 0...1.
public struct PadState: Equatable, Sendable {
    public var buttons: Set<Button> = []
    public var leftX = 0.0, leftY = 0.0
    public var rightX = 0.0, rightY = 0.0
    public var leftTrigger = 0.0, rightTrigger = 0.0

    public init() {}

    /// Encode as input report 1 (report ID first).
    public func bluetoothInputReport() -> Data {
        var r = [UInt8](repeating: 0, count: XboxBluetooth.inputReportSize)
        r[0] = XboxBluetooth.inputReportID

        func put16(_ offset: Int, _ v: UInt16) {
            r[offset] = UInt8(v & 0xFF)
            r[offset + 1] = UInt8(v >> 8)
        }
        // HID Y axes grow downward; PadState Y is up-positive.
        put16(1, Self.stick(leftX))
        put16(3, Self.stick(-leftY))
        put16(5, Self.stick(rightX))
        put16(7, Self.stick(-rightY))
        put16(9, Self.trigger(leftTrigger))
        put16(11, Self.trigger(rightTrigger))
        r[13] = hat

        var bits: UInt16 = 0
        for b in buttons { if let bit = b.reportBit { bits |= 1 << bit } }
        put16(14, bits)
        r[16] = buttons.contains(.share) ? 0x01 : 0x00
        return Data(r)
    }

    public var hat: UInt8 {
        let up = buttons.contains(.dpadUp), down = buttons.contains(.dpadDown)
        let left = buttons.contains(.dpadLeft), right = buttons.contains(.dpadRight)
        let v = (up && !down) ? 1 : (down && !up) ? -1 : 0
        let h = (right && !left) ? 1 : (left && !right) ? -1 : 0
        switch (v, h) {
        case (1, 0): return 1
        case (1, 1): return 2
        case (0, 1): return 3
        case (-1, 1): return 4
        case (-1, 0): return 5
        case (-1, -1): return 6
        case (0, -1): return 7
        case (1, -1): return 8
        default: return 0
        }
    }

    private static func stick(_ v: Double) -> UInt16 {
        let c = min(max(v, -1), 1)
        return UInt16((c + 1) / 2 * 65535 + 0.5)
    }

    private static func trigger(_ v: Double) -> UInt16 {
        UInt16(min(max(v, 0), 1) * 1023 + 0.5)
    }
}
