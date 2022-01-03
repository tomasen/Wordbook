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
    
    @Published var working: Int16 = 0
    @Published var good: Int16    = 0
    @Published var queue: Int16   = 0

    @Published var totalWords: Int = 0
    @Published var totalLearningDays: Int = 0
    
    private let moc = CoreDataManager.shared.container.viewContext
    
    func update() {
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: "WordCard")
        req.predicate = NSPredicate(format: "category >= 0")
        totalWords = try! moc.count(for: req)
        
        totalLearningDays = CoreDataManager.shared.countBy("Engagement", pred: NSPredicate(format: "checked = true"))
    }
    
    func updateStat() {
        let e = WordManager.shared.fetchEngagement()
        working = e.working
        good = e.good
        queue = max(e.goal - e.working - e.good, 0)
    }
}

