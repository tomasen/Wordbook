//
//  PausableTimer.swift
//  Wordbook
//
//  Created by SHEN SHENG on 12/24/21.
//

import Foundation

class PausableTimer {
    static let shared = PausableTimer()
    
    private var duration : TimeInterval = 0
    private var startTime: Date? = nil
    private var counting : Bool = false
 
    // TODO: reset if its a new day
    func reset() {
        duration = 0
        startTime = nil
        counting = false
    }
    
    // reset and restart
    func restart() {
        reset()
        start()
    }
    
    func pause() {
        if counting {
            calc()
            startTime = nil
        }
    }
 
    func start() {
        startTime = Date()
        counting = true
    }
    
    func resume() {
        if counting {
            startTime = Date()
        }
    }
    
    func end() -> TimeInterval {
        pause()
        counting = false
        return duration
    }
    
    private func calc() {
        if let d = startTime {
            duration += d.distance(to: Date())
        }
    }
}

