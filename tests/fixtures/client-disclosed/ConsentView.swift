import SwiftUI

// fixture: client-facing string that names the provider (signal B should
// find this and produce PASS).
struct ConsentView: View {
    var body: some View {
        Text("This app uses OpenAI to generate suggestions.")
    }
}
