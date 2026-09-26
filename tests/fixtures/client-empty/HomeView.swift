import SwiftUI

// fixture: client-facing UI with no mention of any AI provider name
// (signal B must NOT find disclosure here).
struct HomeView: View {
    var body: some View {
        Text("Welcome back!")
    }
}
