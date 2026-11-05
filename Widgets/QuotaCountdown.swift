import SwiftUI

struct QuotaCountdown: View {
    let provider: Provider
    let start: Date
    let reset: Date

    var body: some View {
        if provider == .copilot, reset.timeIntervalSince(start) >= 86_400 {
            if #available(iOS 18.0, *) {
                Text(.currentDate, format: .offset(
                    to: reset, allowedFields: [.day, .hour, .minute, .second],
                    maxFieldCount: 2, sign: .never))
            } else {
                Text(reset, style: .relative)
            }
        } else {
            Text(timerInterval: start...reset, countsDown: true)
        }
    }
}
