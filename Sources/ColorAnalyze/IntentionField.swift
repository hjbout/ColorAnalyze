import ColorCore
import SwiftUI

/// A note about the feeling a photo or series should get, with a few mood words to click.
/// Written before choosing a harmony, so the harmony serves it.
struct IntentionField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    ForEach(Intention.moods, id: \.self) { mood in
                        Toggle(mood.capitalized, isOn: Binding(
                            get: { Intention.contains(mood, in: text) },
                            set: { _ in text = Intention.toggling(mood, in: text) }
                        ))
                    }
                } label: {
                    Label("Moods", systemImage: "plus.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add or remove a mood word")
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .help("Write down the feeling you want before you choose a harmony. It is saved with the session and shown in the report.")
        }
    }
}
