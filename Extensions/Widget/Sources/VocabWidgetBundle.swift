// SPIKE CODE (IOS_PLAN.md stage I0) — replaced in I4 (VoiceCaptureWidget, localized strings).
//
// A static widget for Home Screen and Lock Screen whose only job is to open the app with `vocabapp://voice`.
// No App Group, no timeline updates.

import SwiftUI
import WidgetKit

@main
struct VocabWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoiceSpikeWidget()
    }
}

struct SpikeEntry: TimelineEntry {
    let date: Date
}

struct SpikeProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpikeEntry {
        SpikeEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SpikeEntry) -> Void) {
        completion(SpikeEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpikeEntry>) -> Void) {
        completion(Timeline(entries: [SpikeEntry(date: Date())], policy: .never))
    }
}

struct VoiceSpikeWidget: Widget {
    let kind = "VoiceSpikeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpikeProvider()) { _ in
            SpikeWidgetView()
        }
        .configurationDisplayName("VocabApp")
        .description("Spike: opens VocabApp via vocabapp://voice")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct SpikeWidgetView: View {
    /// `URL(string:)` is optional; `widgetURL(_:)` accepts `URL?`, so no force unwrap is needed.
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
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                VStack(alignment: .leading) {
                    Text("VocabApp").font(.headline)
                    Text("Tap to speak").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.largeTitle)
                Text("VocabApp")
                    .font(.headline)
                Text("I0 spike")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
