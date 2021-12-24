//
//  WordbookApp.swift
//  Shared
//
//  Created by SHEN SHENG on 10/1/21.
//

import SwiftUI

@main
struct WordbookApp: App {
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    let persistenceController = CoreDataManager.shared

    var body: some Scene {
        WindowGroup {
            MasterView()
                .environment(\.colorScheme, .dark)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
        .onChange(of: scenePhase) { (newScenePhase) in
                    switch newScenePhase {
                    case .active:
                        PausableTimer.shared.resume()
                        print("scene is now active!")
                    case .inactive:
                        PausableTimer.shared.pause()
                        print("scene is now inactive!")
                    case .background:
                        PausableTimer.shared.pause()
                        print("scene is now in the background!")
                    @unknown default:
                        print("Apple must have added something new!")
                    }
                }
    }
}
