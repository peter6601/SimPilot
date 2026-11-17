import SwiftUI

/// UI test runner 需要一個宿主 app；它本身不做事，也不會被啟動。
@main struct SimPilotHostApp: App {
    var body: some Scene { WindowGroup { Text("SimPilot runner host") } }
}
