//
//  WordbookApp.swift
//  Shared
//
//  Created by SHEN SHENG on 10/1/21.
//

import SwiftUI

@main
struct WordbookApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
