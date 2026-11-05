import SwiftUI

extension Provider {
    var accent: Color {
        switch self {
        case .codex: return Color(red: 0.55, green: 0.94, blue: 0.77)
        case .copilot: return Color(red: 0.77, green: 0.70, blue: 1)
        case .claude: return Color(red: 0.95, green: 0.65, blue: 0.48)
        }
    }

    var logoAsset: String? {
        switch self {
        case .codex: return nil
        case .copilot: return "CopilotLogo"
        case .claude: return "ClaudeLogo"
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "terminal"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sun.max"
        }
    }
}

struct ProviderLogo: View {
    let provider: Provider
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let asset = provider.logoAsset {
                Image(asset).resizable().scaledToFit()
            } else {
                Image(systemName: provider.symbol).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(provider.accent)
        .accessibilityHidden(true)
    }
}

func creditAmount(_ amount: Double) -> String {
    let formatter = NumberFormatter()
    // Spanish's default omits grouping for four digits; keep all credit counts grouped.
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSeparator = Locale.current.groupingSeparator
    formatter.decimalSeparator = Locale.current.decimalSeparator
    formatter.maximumFractionDigits = 1
    return formatter.string(from: NSNumber(value: amount)) ?? amount.formatted()
}
