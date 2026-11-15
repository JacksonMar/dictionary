import SwiftUI
import WidgetKit

/// Віджети VocabApp (IOS_PLAN §7 I4). Розширення не залежить від VocabCore, не має App Group і не пише звук:
/// єдине завдання — відкрити застосунок посиланням `vocabapp://voice`, і аркуш додавання одразу слухає.
@main
struct VocabWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoiceCaptureWidget()
    }
}
