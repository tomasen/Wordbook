//
//  PushNotificationReceiver.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/5/22.
//

import SwiftUI
import UserNotifications

class PushNotificationReceiver: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushNotificationReceiver()
    
    @Published var notificatedWord: String?
    
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        
        if let w = response.notification.request.content.userInfo["word"] as? String {
            print("MSG: didReceive \(w)")
            DispatchQueue.main.async {
                if response.actionIdentifier == "good" {
                    WordManager.shared.answer(w, .WELLKNOWN)
                }
                self.notificatedWord = w
            }
        }
        
        // cancle all pending notification
        center.removePendingNotificationRequests(withIdentifiers:["wordbook.notify"])
        
        center.removeAllDeliveredNotifications()
         
        completionHandler()
    }
}
