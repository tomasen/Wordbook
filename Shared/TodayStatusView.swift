//
//  TodayStatusView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/2/22.
//

import SwiftUI

struct TodayStatusView: View {
    @ObservedObject var viewModel: TodaysViewModel
    
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
                                     color: Color("progressWorking"))
                    Divider()
                        .frame(height: 20)
                    TodayWordsColumn(label: "Good",
                                     num: viewModel.good,
                                     color: Color("progressGood"))
                    Divider()
                        .frame(height: 20)
                    TodayWordsColumn(label: "Queue",
                                     num: viewModel.queue,
                                     color: Color("progressBackground"))
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
        TodayStatusView(viewModel: TodaysViewModel())
    }
}
