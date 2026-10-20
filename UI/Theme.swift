import SwiftUI

/// 配色，取自 Android 版 `res/values/colors.xml`。
/// 深色底 + 粉/绿/琥珀状态色，与原界面一致。
enum Palette {
    static let bgRoot = Color(hex: 0x10141C)
    static let card = Color(hex: 0x1A2130)
    static let cardStroke = Color(hex: 0x2A3446)

    static let textPrimary = Color(hex: 0xEDF2FA)
    static let textSecondary = Color(hex: 0x8B9BB4)
    static let textHint = Color(hex: 0x5C6A7E)

    static let pink = Color(hex: 0xFF8FB1)
    static let pinkDim = Color(hex: 0x55303E)
    static let accent = Color(hex: 0x4DA3FF)

    static let stateOk = Color(hex: 0x4DD08A)
    static let stateWarn = Color(hex: 0xFFC857)
    static let stateErr = Color(hex: 0xFF6B6B)

    static let btnTextOn = Color.white
    static let voiceIdle = Color(hex: 0x5C6A7E)
    static let voiceBubbleSys = Color(hex: 0x1A2130)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

/// 卡片容器：圆角、细边框、深色填充
struct CardModifier: ViewModifier {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Palette.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func doroCard(padding: CGFloat = 14, cornerRadius: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

/// 主按钮（粉色渐变填充）
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Palette.bgRoot)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.pink, Color(hex: 0xFFB3C8)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

/// 次要按钮（描边）
struct ControlButtonStyle: ButtonStyle {
    var enabled: Bool = true
    var highlighted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(highlighted ? Palette.pink : Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(highlighted ? Palette.pinkDim.opacity(0.5) : Color(hex: 0x1E2636))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(highlighted ? Palette.pink.opacity(0.6) : Palette.cardStroke, lineWidth: 1)
            )
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// 输入框样式
struct DoroTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var isSecure: Bool = false
    var maxLength: Int? = nil

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: promptText)
            } else {
                TextField("", text: $text, prompt: promptText)
                    .keyboardType(keyboard)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .font(.system(size: 14))
        .foregroundColor(Palette.textPrimary)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: 0x151B27))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.cardStroke, lineWidth: 1)
        )
        .onChange(of: text) { newValue in
            if let maxLength = maxLength, newValue.count > maxLength {
                text = String(newValue.prefix(maxLength))
            }
        }
    }

    private var promptText: Text {
        Text(placeholder).foregroundColor(Palette.textHint)
    }
}

/// 小节标题
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(Palette.textPrimary)
    }
}

/// 分隔线
struct Divider1: View {
    var body: some View {
        Rectangle()
            .fill(Palette.cardStroke)
            .frame(height: 1)
    }
}
