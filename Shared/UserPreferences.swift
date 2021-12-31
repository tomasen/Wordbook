//
//  SharedDefaults.swift
//  Memorable
//
//  Created by tomasen on 5/4/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import Foundation


class UserPreferences {
    private let mySharedDefaults = UserDefaults(suiteName: SHARED_DEFAULTS_SUITENAME)!

    static let DKEY_SUPER_USER = "SUPER_USER"
    static let DKEY_CLKCOMPL_WORD = "CLKCOMPL_WORD"
    
    static let SHARED_WORDKEY_PREFIX = "WORDBOOK_"
    static let SHARED_DEFAULTS_SUITENAME = "group.ai.sagittarius.memorable"


    static let shared = UserPreferences()
    
    func bool(forKey key: String) -> Bool {
        var b2 = false
        #if !os(watchOS)
            b2 = NSUbiquitousKeyValueStore.default.bool(forKey: key)
        #endif
        return b2 || mySharedDefaults.bool(forKey: key)
    }
    
    func set(_ v: Bool, forKey key: String) {
        mySharedDefaults.set(v, forKey: key)
        #if !os(watchOS)
            NSUbiquitousKeyValueStore.default.set(v, forKey: key)
        #endif
    }
    
    func set(_ v: Date, forKey key: String) {
        mySharedDefaults.set(v, forKey: key)
        #if !os(watchOS)
            NSUbiquitousKeyValueStore.default.set(v, forKey: key)
        #endif
    }
    
    
    func addToWordbook(_ word: String) {
        set(Date(), forKey: UserPreferences.SHARED_WORDKEY_PREFIX + word)
    }
    
    func dictionaryRepresentation() -> [String : Any] {
        mySharedDefaults.dictionaryRepresentation()
    }
    
    func removeObject(forKey key: String) {
        mySharedDefaults.removeObject(forKey: key)
    }
}

