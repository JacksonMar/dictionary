import Foundation
import SwiftUI
import WidgetKit

/// Єдиний запис таймлайну: вміст віджета статичний.
struct VoiceCaptureEntry: TimelineEntry {
    let date: Date
}

/// Один запис і політика `.never` — віджет ніколи не оновлюється (немає даних, немає App Group).
struct VoiceCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> VoiceCaptureEntry {
        VoiceCaptureEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (VoiceCaptureEntry) -> Void) {
        completion(VoiceCaptureEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VoiceCaptureEntry>) -> Void) {
        completion(Timeline(entries: [VoiceCaptureEntry(date: Date())], policy: .never))
    }
}

/// «Додати голосом» на екрані «Домівка» (`.systemSmall`) і на заблокованому екрані (`.accessoryCircular`,
/// `.accessoryRectangular`). Дотик → `vocabapp://voice` → `Router` застосунку відкриває аркуш у режимі голосу.
///
/// Тексти (DI17) — ключі `widget.*` у `Extensions/Widget/Resources/{en,uk}.lproj/Localizable.strings` бандла
/// розширення: `Text("…")` з літералом — це `LocalizedStringKey`. Мова — мова системи (налаштування мови застосунку
/// віджету недоступні: App Group немає).
struct VoiceCaptureWidget: Widget {
    static let kind = "VoiceCaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: VoiceCaptureProvider()) { _ in
            VoiceCaptureWidgetView()
        }
        .configurationDisplayName(Text("widget.voice.displayName"))
        .description(Text("widget.voice.description"))
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct VoiceCaptureWidgetView: View {
    /// `URL(string:)` повертає опціонал; `widgetURL(_:)` приймає `URL?`, тож примусове розгортання не потрібне.
    static let voiceURL = URL(string: "vocabapp://voice")

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(Self.voiceURL)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("widget.voice.action"))
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("widget.voice.title")
                        .font(.headline)
                    Text("widget.voice.action")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        default:
            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("widget.voice.title")
                    .font(.headline)
                Text("widget.voice.action")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
