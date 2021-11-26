//
//  WordbookApp.swift
//  Shared
//
//  Created by SHEN SHENG on 10/1/21.
//

import SwiftUI

@main
struct WordbookApp: App {
    let persistenceController = CoreDataManager.shared

    var body: some Scene {
        WindowGroup {
            MasterView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
