//
//  StoreManager.swift
//  Memorable
//
//  Created by tomasen on 5/2/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import Foundation
import StoreKit
import SwiftUI
import SwiftyStoreKit

class InAppPurchaseManager: ObservableObject {
    private let productId = "ai.sagittarius.memorable.iap.better.explanation.monthly"
    private let sharedSecret = "1396e8fa1d95489f873667c7d8d79a88"
    
    static let shared = InAppPurchaseManager()
    
    @Published var localizedPrice: String?
    
    var isProSubscriber: Bool {
        UserPreferences.shared.bool(forKey: "WBCFG_PROVALID")
    }
    
    var isSuperUser: Bool {
        UserPreferences.shared.bool(forKey: UserPreferences.DKEY_SUPER_USER)
    }
    
    init() {
        onLaunch()
    }
    
    func toggleSuperUser() {
        UserPreferences.shared.set(!isSuperUser, forKey: UserPreferences.DKEY_SUPER_USER)
    }
    
    func toggleProFeatures() {
        enableProFeatures(!isProSubscriber)
    }
    
    // setProFeatures
    func enableProFeatures(_ v: Bool) {
        UserPreferences.shared.set(v, forKey: "WBCFG_PROVALID")
    }
    
    private func onLaunch() {
        // see notes below for the meaning of Atomic / Non-Atomic
        SwiftyStoreKit.completeTransactions(atomically: true) { purchases in
            for purchase in purchases {
                switch purchase.transaction.transactionState {
                case .purchased, .restored:
                    if purchase.needsFinishTransaction {
                        // Deliver content from server, then:
                        SwiftyStoreKit.finishTransaction(purchase.transaction)
                    }
                    // Unlock content
                    self.enableProFeatures(true)
                    return
                case .failed, .purchasing, .deferred:
                    break // do nothing
                default:
                    break
                }
            }
        }
        
        validate()
        
        SwiftyStoreKit.retrieveProductsInfo([productId]) { result in
            if let product = result.retrievedProducts.first {
                self.localizedPrice = product.localizedPrice
            }
        }
    }
    
    func subscribe() {
        SwiftyStoreKit.purchaseProduct(productId, atomically: true) { result in
            if case .success(let purchase) = result {
                // Deliver content from server, then:
                if purchase.needsFinishTransaction {
                    SwiftyStoreKit.finishTransaction(purchase.transaction)
                }
                
                self.validate()
            } else {
                // purchase error
                print("purchase error \(result)")
            }
        }
    }
    
    func validate() {
        let appleValidator = AppleReceiptValidator(service: .production, sharedSecret: sharedSecret)
        SwiftyStoreKit.verifyReceipt(using: appleValidator) { result in
            switch result {
            case .success(let receipt):
                let productIds = Set([self.productId])
                let purchaseResult = SwiftyStoreKit.verifySubscriptions(productIds: productIds, inReceipt: receipt)
                switch purchaseResult {
                case .purchased(let expiryDate, let items):
                    print("\(productIds) are valid until \(expiryDate)\n\(items)\n")
                    self.enableProFeatures(true)
                    return
                case .expired(let expiryDate, let items):
                    print("\(productIds) are expired since \(expiryDate)\n\(items)\n")
                case .notPurchased:
                    print("The user has never purchased \(productIds)")
                }
            case .error(let error):
                print("Receipt verification failed: \(error)")
            }
            self.enableProFeatures(false)
        }
    }
    
    func restore() {
        SwiftyStoreKit.restorePurchases() { result in
            for product in result.restoredPurchases {
                if product.needsFinishTransaction {
                    SwiftyStoreKit.finishTransaction(product.transaction)
                }
                if product.productId == self.productId {
                    self.validate()
                }
            }
        }
    }
}
