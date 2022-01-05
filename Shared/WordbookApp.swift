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

    private let persistenceController = CoreDataManager.shared
    private let pushReceiver = PushNotificationReceiver.shared

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
                        scheduleWordReminderNotification()
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
                if let wc = WordManager.shared.addWordCard(word) {
                    wc.duedate = v
                }
                // remove key
                UserPreferences.shared.removeObject(forKey:k)
            }
        }
    }
    
    private func scheduleWordReminderNotification() {
        func notify() {
            let word = WordManager.shared.nextWord()
            if word.count == 0 {
                return
            }
            
            let content = UNMutableNotificationContent()
            content.title = "Wordbook"
            content.body = "Do you still remember \(word)?"
            content.userInfo = ["word": word]
            content.categoryIdentifier = "wordReminder"
            content.threadIdentifier = "wordbook-word"
            content.sound = UNNotificationSound.default

            // Create the trigger as a repeating event.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 15*60, repeats: false)
            
            let request = UNNotificationRequest(identifier: "wordbook.notify",
                        content: content, trigger: trigger)
            
            // Schedule the request with the system.
            let notificationCenter = UNUserNotificationCenter.current()
            notificationCenter.add(request) { (error) in
                if error != nil {
                    // Handle any errors.
                    print(error ?? "unknown error")
                }
            }
        }
        
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard (settings.authorizationStatus == .authorized) ||
                  (settings.authorizationStatus == .provisional) else {
                center.requestAuthorization(options: [.alert, .provisional]) { (granted, error) in
                    if granted {
                        notify()
                    }
                }
                return
            }

            notify()
        }
    }
}
