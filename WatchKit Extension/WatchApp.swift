//
//  WatchApp.swift
//  Watch WatchKit Extension
//
//  Created by SHEN SHENG on 12/31/21.
//

import SwiftUI

@main
struct WatchApp: App {
    @SceneBuilder var body: some Scene {
        WindowGroup {
            NavigationView {
                WatchMasterView()
                    .environment(\.colorScheme, .dark)
            }
        }

        WKNotificationScene(controller: NotificationController.self, category: "myCategory")
    }
}
