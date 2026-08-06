//
//  FlipView.swift
//  Memorable
//
//  Created by tomasen on 3/15/20.
//  Copyright © 2020 tomasen. All rights reserved.
//

/*
Abstract:
The flip view container applies a 3D horizontal rotation effect to two views.
*/

import SwiftUI

class FlipViewSize : ObservableObject {
    @Published var height : CGFloat
    @Published var width : CGFloat
    
    init(height: CGFloat, width: CGFloat) {
        self.height = height
        self.width = width
    }
}

struct FlipView<Front: View, Back: View> : View {
    let front: Front
    let back: Back
    let tap: () -> Void
    @Binding var flipped: Bool
    @Binding var disabled: Bool

    init(_ front: Front, _ back: Back,
         tap: @escaping () -> Void,
         flipped: Binding<Bool>,
         disabled: Binding<Bool>) {
        self.front = front
        self.back = back
        self.tap = tap
        self._flipped = flipped
        self._disabled = disabled
    }

    var body: some View {
        GeometryReader {
            FlipContent(front: self.front,
                        back: self.back,
                        size: $0.size,
                        tap: self.tap,
                        flipped: self.$flipped,
                        disabled: self.$disabled)
                // .environmentObject(FlipViewSize(height:$0.size.height, width:$0.size.width))
        }
    }
}

/**
 The FlipContent view applies a 3D rotation effect to the view when it is either
 tapped or dragged. To achieve the desired effect of the card having both a
 "front" and "back", when the view reaches 90 degrees of rotation the "front"
 view becomes translucent and the "back" view becomes opaque. This allows for
 seamlessly switching between the two views during the animation.
 */
private struct FlipContent<Front: View, Back: View> : View {
    let front: Front
    let back: Back
    let size: CGSize
    let tap: () -> Void
    @Binding var flipped: Bool
    @Binding var disabled: Bool

    @State var angleTranslation: Double = 0.0

    init(front: Front, back: Back, size: CGSize,
         tap: @escaping () -> Void,
         flipped: Binding<Bool>,
         disabled: Binding<Bool>) {
        self.front = front
        self.back = back
        self.size = size
        self.tap = tap
        self._flipped = flipped
        self._disabled = disabled
    }
    
    func flip() {
        withAnimation {
            self.flipped.toggle()
            self.angleTranslation = 0.0
        }
    }
    
    var body: some View {
        ZStack(alignment: .center) {
            front
                .opacity(self.showingFront ? 1.0 : 0.0)
                .allowsHitTesting(self.showingFront)
            back
                .scaleEffect(CGSize(width: -1.0, height: 1.0))
                .opacity(self.showingFront ? 0.0 : 1.0)
                .allowsHitTesting(!self.showingFront)
        }
        .frame(minWidth: 0.0, maxWidth: .infinity, minHeight: 0.0, maxHeight: .infinity, alignment: .center)
        .rotation3DEffect(.degrees(self.totalAngle), axis: (0.0, 1.0, 0.0), perspective: 0.5)
        .contentShape(Rectangle())
        // Only the visible front owns the whole-card reveal gesture. Keeping
        // a disabled gesture over the back competes with its title Button and
        // can consume a pronunciation tap without doing anything. Once the
        // definition is visible, its controls own their taps independently.
        .gesture(
            TapGesture().onEnded {
                self.flip()
                self.tap()
            },
            including: (!self.disabled && self.showingFront) ? .all : .subviews
        )
        /*
        .simultaneousGesture(
            self.disabled ? nil :
            DragGesture(minimumDistance: 5, coordinateSpace: .local)
                .onChanged { value in
                    self.angleTranslation = Double((value.translation.width / self.size.width)) * 180.0
                }
                .onEnded { value in
                    let endAngle = Double((value.predictedEndTranslation.width / self.size.width)) * 180.0
                    
                    withAnimation{
                        if endAngle >= 90.0 {
                            if self.flipped {
                                self.angleTranslation = 0
                            } else {
                                self.angleTranslation = 360
                            }
                            self.flipped.toggle()
                        } else if endAngle < -90.0 {
                            if self.flipped {
                                self.angleTranslation = -360
                            } else {
                                self.angleTranslation = 0
                            }
                            self.flipped.toggle()
                        } else {
                            self.angleTranslation = 0
                        }
                    }
                })
        */
    }
    
    var baseAngle: Double {
        self.flipped ? -180 : 0
    }
    
    var totalAngle: Double {
        baseAngle + angleTranslation
    }

    var clampedAngle: Double {
        var clampedAngle = angleTranslation + baseAngle
        while clampedAngle < 360.0 {
            clampedAngle += 360.0
        }
        return clampedAngle.truncatingRemainder(dividingBy: 360.0)
    }

    var showingFront: Bool {
        return clampedAngle < 90.0 || clampedAngle > 270.0
    }
}

struct TranslatingAngleState {
    @Binding var flipped: Bool
    
    init(_ flipped: Binding<Bool>) {
        self._flipped = flipped
    }
    
    var angleTranslation: Double = 0.0
    
    var angle: Double {
        self.flipped ? -180 : 0
    }
    
    var total: Double {
        angle + angleTranslation
    }

    var clamped: Double {
        var clampedAngle = angleTranslation + angle
        while clampedAngle < 360.0 {
            clampedAngle += 360.0
        }
        return clampedAngle.truncatingRemainder(dividingBy: 360.0)
    }

    var showingFront: Bool {
        let clampedAngle = clamped
        return clampedAngle < 90.0 || clampedAngle > 270.0
    }
}

struct FlipView_Previews: PreviewProvider {
    static var previews: some View {
        FlipView(Text("Front"),
                 Text("Back"),
                 tap: {},
                 flipped: .constant(false),
                 disabled: .constant(false))
        
    }
}
