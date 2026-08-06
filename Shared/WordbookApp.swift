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
            // UserNotifications invokes its settings/authorization callbacks
            // on a private queue. WordManager owns Core Data's main-queue
            // view context, so select the reminder word on the main queue.
            DispatchQueue.main.async {
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

                let trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: 15 * 60,
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: "wordbook.notify",
                    content: content,
                    trigger: trigger
                )

                UNUserNotificationCenter.current().add(request) { error in
                    if let error {
                        print(error)
                    }
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
    @ObservedObject private var tutorManager = LocalTutorManager.shared

    var body: some View {
        #if WORDBOOK_LOCAL_LLM
        Group {
            if tutorManager.isReady && isNaturalVoicePrepared {
                MasterView()
            } else {
                PreparationView(
                    soundManager: soundManager,
                    tutorManager: tutorManager
                )
            }
        }
        .task {
            tutorManager.prepare()
            #if WORDBOOK_NATURAL_VOICE
            soundManager.prepareNaturalVoice()
            #endif
        }
        #else
        MasterView()
        #endif
    }

    private var isNaturalVoicePrepared: Bool {
        #if WORDBOOK_NATURAL_VOICE
        soundManager.isNaturalVoiceReady
        #else
        true
        #endif
    }
}

#if WORDBOOK_LOCAL_LLM
private struct PreparationView: View {
    @ObservedObject var soundManager: SoundManager
    @ObservedObject var tutorManager: LocalTutorManager
    @State private var preparationStartedAt = Date()

    private var error: String? {
        tutorManager.preparationError ?? soundManager.naturalVoiceError
    }

    private var preparationStatus: String {
        if !tutorManager.isReady {
            return tutorManager.preparationStatus
        }
        if !soundManager.isNaturalVoiceReady {
            return soundManager.naturalVoicePreparationStatus
        }
        return "Almost ready…"
    }

    var body: some View {
        ZStack {
            Color("Background")
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                VStack(spacing: 26) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundColor(Color("fontLink"))
                        .frame(width: 72, height: 72)
                        .background(
                            Circle()
                                .fill(Color("BackgroundHighlight"))
                        )

                    VStack(spacing: 10) {
                        Text("Getting Wordbook ready")
                            .font(.title2.weight(.semibold))
                        Text("Setting up the local language model and pronunciation on this device.")
                            .font(.subheadline)
                            .foregroundColor(Color("fontGray"))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error {
                        errorPanel(error)
                    } else {
                        statusPanel
                        Text("Initial setup can take a little longer.")
                            .font(.footnote)
                            .foregroundColor(Color("fontGray"))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 28)

                Spacer(minLength: 28)

                if error == nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                            Text(elapsedText(at: context.date))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Color("fontGray").opacity(0.75))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Setup time")
                        .accessibilityValue(elapsedAccessibilityText(at: context.date))
                    }
                    .padding(.bottom, 22)
                }
            }
            .foregroundColor(Color("fontBody"))
        }
    }

    private var statusPanel: some View {
        HStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
                .tint(Color("fontLink"))
            Text(preparationStatus)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 62)
        .background(panelBackground)
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 16) {
            Label("We couldn’t finish setup", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(Color("fontTitle"))
            Text(message)
                .font(.footnote)
                .foregroundColor(Color("fontGray"))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") {
                preparationStartedAt = Date()
                if tutorManager.preparationError != nil {
                    tutorManager.retryPreparation()
                }
                if soundManager.naturalVoiceError != nil {
                    soundManager.retryNaturalVoicePreparation()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("fontLink"))
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color("BackgroundHighlight"))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color("fontBody").opacity(0.10), lineWidth: 1)
            }
    }

    private func elapsedText(at date: Date) -> String {
        let elapsed = max(Int(date.timeIntervalSince(preparationStartedAt)), 0)
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private func elapsedAccessibilityText(at date: Date) -> String {
        let elapsed = max(Int(date.timeIntervalSince(preparationStartedAt)), 0)
        return "\(elapsed / 60) minutes, \(elapsed % 60) seconds"
    }
}
#endif
