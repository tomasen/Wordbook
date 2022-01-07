//
//  TodaysViewModel.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/3/22.
//

import Foundation
import SwiftUI
import CoreData

class TodaysViewModel: ObservableObject {
    var todayDateString = WordManager.shared.todayDateString()
    
    // not so good yet, including vague
    @Published var working: Int16 = 0
    // finished with good
    @Published var good: Int16    = 0
    // how many words left till reach daily goal
    @Published var queue: Int16   = 0
    
    @Published var totalWordsInWordbook: Int = 0
    @Published var totalLearningDays: Int = 0
    
    @Published var goal: Int16 = 15
    
    private let moc = CoreDataManager.shared.container.viewContext
    
    func update() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "category >= 0")
        totalWordsInWordbook = try! moc.count(for: req)
        
        totalLearningDays = CoreDataManager.shared.countBy("Engagement", pred: NSPredicate(format: "checked = true"))
    }
    
    func updateStat() {
        let e = WordManager.shared.fetchEngagement()
        let goal = Int16(max(UserPreferences.shared.dailyGoal, 1))
        working = e.working
        good = e.good
        queue = max(goal - e.working - e.good, 0)
    }
}

