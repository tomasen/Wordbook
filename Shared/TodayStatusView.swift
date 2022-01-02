//
//  TodayStatusView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/2/22.
//

import SwiftUI

class TodayStatusViewModel: ObservableObject {
    var todayDateString = WordManager.shared.todayDateString()
    
    @Published var working: Int16 = 0
    @Published var good: Int16    = 0
    @Published var queue: Int16   = 0
    
    func updateStat() {
        let e = WordManager.shared.fetchEngagement()
        working = e.working
        good = e.good
        queue = max(e.goal - e.working, 0)
    }
}

struct TodayStatusView: View {
    @StateObject private var viewModel = TodayStatusViewModel()
    
    private var didDataChange =  NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)
    
    var body: some View {
        VStack{
            VStack{
                HStack(alignment: .firstTextBaseline) {
                    Text("Today")
                        .foregroundColor(Color("fontGray"))
                        .customFont(name: "AvenirNext-Heavy", style: .title3)
                    Spacer()
                    
                    Text("\(viewModel.todayDateString)")
                        .customFont(name: "AvenirNext-DemiBold", style: .caption1)
                        .foregroundColor(Color("fontGray"))
                }
                Divider()
                HStack{
                    TodayWordsColumn(label: "Working",
                                     num: viewModel.working,
                                     color: Color("progressGood"))
                    Divider()
                        .frame(height: 20)
                    TodayWordsColumn(label: "Good",
                                     num: viewModel.good,
                                     color: Color("progressBad"))
                    Divider()
                        .frame(height: 20)
                    TodayWordsColumn(label: "Queue",
                                     num: viewModel.queue,
                                     color: Color("progressBackground"))
                }
                .onAppear{
                    viewModel.updateStat()
                }
                .onReceive(didDataChange) { _ in
                    viewModel.updateStat()
                }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 28, trailing: 20))
        }
        .foregroundColor(Color("fontBody"))
        .background(Rectangle().fill(Color("todayBackgroundHighlight")).shadow(radius: 2).cornerRadius(12))
    }
    
    func TodayWordsColumn(label: String, num: Int16, color: Color) -> some View {
        HStack {
            Spacer()
            VStack{
                Text("\(label)")
                    .foregroundColor(Color("fontGray"))
                    .padding(5)
                
                Text("\(num)")
                    .customFont(name: "Avenir-Medium", style: .title3)
                Rectangle()
                    .fill(color)
                    .frame(width:30, height:3)
            }
            Spacer()
        }
    }
    
}

struct TodayStatusView_Previews: PreviewProvider {
    static var previews: some View {
        TodayStatusView()
    }
}
