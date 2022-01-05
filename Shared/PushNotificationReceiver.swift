//
//  PushNotificationReceiver.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/5/22.
//

import SwiftUI
import UserNotifications

class PushNotificationReceiver: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var notificatedWord: String?
    
    static let shared = PushNotificationReceiver()
    
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        
        if let w = response.notification.request.content.userInfo["word"] as? String {
            switch response.actionIdentifier {
            case "good":
                WordManager.shared.answer(w, .WELLKNOWN)
                break
            default:
                break
            }
            
            notificatedWord = w
        }
        
        // cancle all pending notification
        center.removePendingNotificationRequests(withIdentifiers:["wordbook.notify"])
         
        completionHandler()
    }
}
