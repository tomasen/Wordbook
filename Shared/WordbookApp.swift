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
    
    func onActive() {
        // sort the word list first
        var dict = Dictionary<String, Date>()
        for (k, v) in UserPreferences.shared.dictionaryRepresentation(){
            if let d = v as? Date {
                if k.hasPrefix(UserPreferences.SHARED_WORDKEY_PREFIX){
                    // need prefix to filter keys
                    dict[k] = d
                }
            }
        }
        
        for (k, v) in dict.sorted(by: { $0.1 < $1.1 }) {
            if var word = k as String? {
                // add word to wordbook
                word = String(word.dropFirst(UserPreferences.SHARED_WORDKEY_PREFIX.count))
                if let wc = WordCard.add(word) {
                    wc.duedate = v
                }
                // remove key
                UserPreferences.shared.removeObject(forKey:k)
            }
        }
    }
}
