//
//  TodaysView.swift
//  Wordbook
//
//  Created by SHEN SHENG on 1/3/22.
//

import SwiftUI

struct TodaysView: View {
    @StateObject var viewModel = TodaysViewModel()
    @StateObject var app = AppStoreManager.shared
    
    private let didDataChange =  NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)
        .debounce(for: 1, scheduler: DispatchQueue.global(qos: .background))
        .receive(on: DispatchQueue.main)
    
    var body: some View {
        VStack{
            NavigationLink(destination: SharingView()) {
                TodayStatusView(viewModel: viewModel)
            }
            
            OverallStatusView()
                .onAppear{
                    viewModel.update()
                }
            
            Spacer()
            NavigationLink(destination: CardView()) {
                StartButton(viewModel: viewModel)
            }
            Spacer()
            if !app.isProUser {
                Divider()
                Button(action: {
                    app.subscribe()
                }) {
                    Text("Upgrade")
                        .font(.callout)
                }
                .customFont(name: "AvenirNext-Medium", style: .body, weight: .medium)
                .buttonStyle(ChoiceButtonStyle())
            }
        }
        .onAppear{
            viewModel.updateStat()
        }
        .onReceive(didDataChange) { _ in
            viewModel.updateStat()
        }
        .padding(EdgeInsets(top: 12+25, leading: 25, bottom: 12, trailing: 25))
        .customFont(name: "AvenirNext-Regular", style: .body)
        .background(Color("Background").edgesIgnoringSafeArea(.all))
    }
    
    func OverallStatusView() -> some View {
        VStack{
            HStack {
                VStack(alignment: .leading){
                    Text("Total")
                        .foregroundColor(Color("fontGray"))
                        .padding(.bottom, 4)
                    HStack (alignment: .firstTextBaseline) {
                        Text("\(viewModel.totalWordsInWordbook)")
                            .customFont(name: "Avenir-Medium", style: .title3)
                        Text("words")
                            .customFont(name: "AvenirNext-Regular", style: .footnote)
                        Spacer()
                    }
                }
                Spacer()
                VStack(alignment: .trailing){
                    Text("Ring Closed")
                        .foregroundColor(Color("fontGray"))
                        .padding(.bottom, 4)
                    HStack (alignment: .firstTextBaseline) {
                        Spacer()
                        Text("\(viewModel.totalLearningDays)")
                            .customFont(name: "Avenir-Medium", style: .title3)
                        Text("days")
                            .customFont(name: "AvenirNext-Regular", style: .footnote)
                    }
                }
            }
            .foregroundColor(Color("fontBody"))
            .padding(20)
        }
    }
}

struct StartButton: View {
    @ObservedObject var viewModel: TodaysViewModel
    @State private var startTextRect: CGRect = CGRect.zero
    
    let progressRotate = -90.0
    var progressCirleWidth: CGFloat {
        let radius = sqrt(pow(startTextRect.size.width/2, 2)
                          + pow(startTextRect.size.height/2, 2))
        return (radius+10) * 2 * 1.2
    }
    var progressLineWidth: CGFloat {
        progressCirleWidth / 12
    }
    var progressWorking: CGFloat {
        progressGoalTotal > 0
        ? CGFloat(viewModel.working) / progressGoalTotal
        : 0
    }
    var progressGood: CGFloat {
        progressGoalTotal > 0
        ? CGFloat(viewModel.working + viewModel.good) / progressGoalTotal
        : 0
    }
    var progressGoalTotal: CGFloat {
        CGFloat(viewModel.working + viewModel.good + viewModel.queue)
    }
    
    var body: some View {
        VStack{
            ZStack {
                Circle()
                    .stroke(Color("progressBackground"), lineWidth: progressLineWidth)
                    .frame(height: progressCirleWidth)
                
                Circle()
                    .trim(from: progressWorking, to: progressGood)
                    .stroke(style: StrokeStyle(lineWidth: progressLineWidth, lineCap: .round, lineJoin: .round))
                    .foregroundColor(Color("progressGood"))
                    .rotationEffect(.degrees(progressRotate))
                    .frame(height: progressCirleWidth)
                
                Circle()
                    .trim(from: 0, to: progressWorking)
                    .stroke(style: StrokeStyle(lineWidth: progressLineWidth, lineCap: .round, lineJoin: .round))
                    .foregroundColor(Color("progressWorking"))
                    .rotationEffect(.degrees(progressRotate))
                    .frame(height: progressCirleWidth)
                
                Circle()
                    .fill(Color("startButtonBackground"))
                    .frame(height: progressCirleWidth-progressLineWidth*2)
                    .shadow(radius: 2)
                    .overlay(
                        VStack {
                            Spacer()
                            VStack{
                                Text("\(Int(progressWorking * 100.0))%")
                                    .foregroundColor(Color("startButtonText"))
                                    .customFont(name: "HelveticaNeue-Bold", style: .largeTitle)
                                    .padding(0)
                                
                                Text(progressWorking >= 1 ? "CARRY ON" :
                                        progressGood > 0 ? "RESUME" : "START")
                                    .padding(0)
                                    .foregroundColor(Color("startButtonText"))
                                    .customFont(name: "AvenirNext-Bold", style: .title1)
                            }
                            .background(RectGetter($startTextRect))
                            Spacer()
                        }
                    )
            }
        }
    }
}

struct TodaysView_Previews: PreviewProvider {
    static var previews: some View {
        TodaysView()
    }
}
