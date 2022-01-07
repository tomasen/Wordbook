//
//  SharedDefaults.swift
//  Memorable
//
//  Created by tomasen on 5/4/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

import Foundation

struct LanguageManifestItem {
    let code: String
    let desc: String
}

class UserPreferences: ObservableObject {
    @Published var dailyGoal = 15 {
        didSet {
            set(dailyGoal, forKey: UserPreferences.DKEY_DAILY_GOAL)
        }
    }
    
    @Published var translationLanguageCode = "" {
        didSet {
            set(translationLanguageCode, forKey: UserPreferences.DKEY_TRANSLATION_LANGUAGE)
        }
    }
    
    // codeString : readable describtion
    let translationLanguageManifest: [String: String] = ["":"None",
                                                         "zh": "Chinese",
                                                         "ja": "Japanese",
                                                         "ru": "Russian",
                                                         "de": "German",
                                                         "fr": "French",
                                                         "es": "Spanish",
                                                         "pt": "Portuguese",
                                                         "it": "Italian",
                                                         "nl": "Dutch",
                                                         "pl": "Polish",
                                                         "bg": "Bulgarian",
                                                         "cs": "Czech",
                                                         "da": "Danish",
                                                         "et": "Estonian",
                                                         "fi": "Finnish",
                                                         "el": "Greek",
                                                         "hu": "Hungarian",
                                                         "lv": "Latvian",
                                                         "lt": "Lithuanian",
                                                         "ro": "Romanian",
                                                         "sk": "Slovak",
                                                         "sl": "Slovenian",
                                                         "sv": "Swedish"]
    
    @Published var testPrepBook = 0 {
        didSet {
            set(testPrepBook, forKey: UserPreferences.DKEY_TEST_PREP_BOOK)
        }
    }
    
    let testPrepBooks: [String] = ["None", "SAT", "TOEFL", "GRE", "GMAT", "IELTS"]
    
    static let shared = UserPreferences()
    
    private let mySharedDefaults = UserDefaults(suiteName: SHARED_DEFAULTS_SUITENAME)!
    
    static let DKEY_SUPER_USER = "SUPER_USER"
    static let DKEY_CLKCOMPL_WORD = "CLKCOMPL_WORD"
    static let DKEY_PROSUBSCRIBER = "WBCFG_PROVALID"
    
    static let SHARED_WORDKEY_PREFIX = "WORDBOOK_"
    static let SHARED_DEFAULTS_SUITENAME = "group.ai.sagittarius.memorable"
    
    static let DKEY_DAILY_GOAL = "DAILY_GOAL"
    static let DKEY_TRANSLATION_LANGUAGE = "TRANSLATION_LANGUAGE"
    static let DKEY_TEST_PREP_BOOK = "TEST_PREP_BOOK"
    
    init() {
        dailyGoal = integer(forKey: UserPreferences.DKEY_DAILY_GOAL)
        if dailyGoal == 0 {
            dailyGoal = 15
        }
        translationLanguageCode = string(forKey: UserPreferences.DKEY_TRANSLATION_LANGUAGE) ?? ""
        testPrepBook = integer(forKey: UserPreferences.DKEY_TEST_PREP_BOOK)
    }
    
    func bool(forKey key: String) -> Bool {
        var b2 = false
#if !os(watchOS)
        b2 = NSUbiquitousKeyValueStore.default.bool(forKey: key)
#endif
        return b2 || mySharedDefaults.bool(forKey: key)
    }
    
    func integer(forKey key: String) -> Int {
#if !os(watchOS)
        return Int(NSUbiquitousKeyValueStore.default.longLong(forKey: key))
#else
        return mySharedDefaults.integer(forKey: key)
#endif
    }
    
    func string(forKey key: String) -> String? {
#if !os(watchOS)
        return NSUbiquitousKeyValueStore.default.string(forKey: key)
#else
        return mySharedDefaults.string(forKey: key)
#endif
    }
    
    func set(_ v: Any, forKey key: String) {
        mySharedDefaults.set(v, forKey: key)
#if !os(watchOS)
        NSUbiquitousKeyValueStore.default.set(v, forKey: key)
#endif
    }
    
    func addToWordbook(_ word: String) {
        set(Date(), forKey: UserPreferences.SHARED_WORDKEY_PREFIX + word)
    }
    
    // TODO: remove these
    func dictionaryRepresentation() -> [String : Any] {
        mySharedDefaults.dictionaryRepresentation()
    }
    
    func removeObject(forKey key: String) {
        mySharedDefaults.removeObject(forKey: key)
    }
    
    // -----------
}

