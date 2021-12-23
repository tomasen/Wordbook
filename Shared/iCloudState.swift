//
//  iCloudState.swift
//  Memorable
//
//  Created by tomasen on 5/2/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import SwiftUI
import CloudKit

class iCloudState: ObservableObject {
    @Published var enabled: Bool
    
    static let shared = iCloudState()

    init () {
        // check icloud statue quick
        if FileManager.default.ubiquityIdentityToken != nil {
            enabled = true
        } else {
            enabled = false
        }
        
        CKContainer.default().accountStatus { (accountStatus, error) in
            var avalible = false
            switch accountStatus {
            case .available:
                avalible = true
                print("iCloud Available")
            case .noAccount:
                print("No iCloud account")
            case .restricted:
                print("iCloud restricted")
            case .couldNotDetermine:
                print("Unable to determine iCloud status")
            default:
                print("Unknown \(accountStatus)")
            }
            DispatchQueue.main.async {
                self.enabled = avalible
            }
        }
    }
}
