//
//  WatchApp.swift
//  Watch WatchKit Extension
//
//  Created by SHEN SHENG on 12/31/21.
//

import SwiftUI

@main
struct WatchApp: App {
    private let pushReceiver = PushNotificationReceiver.shared
    
    @SceneBuilder var body: some Scene {
        WindowGroup {
            WatchMasterView()
                .environment(\.colorScheme, .dark)
        }

        // WKNotificationScene(controller: NotificationController.self, category: "myCategory")
    }
}
