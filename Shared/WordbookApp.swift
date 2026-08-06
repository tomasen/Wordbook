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
            WordbookRootView()
                .environment(\.colorScheme, .dark)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
        .onChange(of: scenePhase) { (newScenePhase) in
                    switch newScenePhase {
                    case .active:
                        PausableTimer.shared.resume()
                        addingNewWordsFromShareExtension()
                        CoreDataManager.shared.refreshAndSync()
                        print("scene is now active!")
                        
                    case .inactive, .background:
                        PausableTimer.shared.pause()
                        CoreDataManager.shared.save()
                        scheduleWordReminderNotification()
                        print("scene is now inactive or in the background!")
                        
                    @unknown default:
                        print("Apple must have added something new!")
                    }
                }
    }
    
    func addingNewWordsFromShareExtension() {
        // sort the word list first
        for (k, v) in UserPreferences.shared.dictionaryRepresentation(){
            if let d = v as? Date {
                if k.hasPrefix(UserPreferences.SHARED_WORDKEY_PREFIX){
                    // need prefix to filter keys
                    
                    let word = String(k.dropFirst(UserPreferences.SHARED_WORDKEY_PREFIX.count))
                    if let wc = WordManager.shared.addWordCard(word) {
                        wc.createdAt = d
                        wc.updateDueByMinute(30)
                        print("MSG: adding word \(word) \(v)")
                    }
                    
                    // remove key
                    UserPreferences.shared.removeObject(forKey:k)
                }
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

private struct WordbookRootView: View {
    @ObservedObject private var soundManager = SoundManager.shared

    var body: some View {
        #if WORDBOOK_NATURAL_VOICE
        Group {
            if soundManager.isNaturalVoiceReady {
                MasterView()
            } else {
                PreparationView(soundManager: soundManager)
            }
        }
        .task {
            soundManager.prepareNaturalVoice()
        }
        #else
        MasterView()
        #endif
    }
}

#if WORDBOOK_NATURAL_VOICE
private struct PreparationView: View {
    @ObservedObject var soundManager: SoundManager

    var body: some View {
        ZStack {
            Color("Background")
                .ignoresSafeArea()

            VStack(spacing: 16) {
                if let error = soundManager.naturalVoiceError {
                    Text("Preparation failed")
                        .font(.headline)
                    Text(error)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        soundManager.retryNaturalVoicePreparation()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView()
                    Text("Preparing…")
                }
            }
            .foregroundColor(Color("fontBody"))
            .padding(32)
        }
    }
}
#endif
