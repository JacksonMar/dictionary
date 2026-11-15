import SwiftUI
import VocabCore

/// Банер підсумку інжесту inbox «Поділитися» (IOS_PLAN §5, I3): скільки слів додано на переклад, скільки вже були
/// в словнику, скільки відхилено / ще не збережено. Показуються лише ненульові лічильники
/// (`MobileAppModel.inboxBannerLines`). Закривається кнопкою; наступний непорожній інжест показує новий звіт.
@MainActor
struct InboxBanner: View {
    let report: InboxIngestReport
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(.inboxBannerTitle))
                    .font(.subheadline.weight(.semibold))
                ForEach(MobileAppModel.inboxBannerLines(for: report), id: \.self) { (line: String) in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(L10n.text(.inboxDismiss)))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
