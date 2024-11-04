import SwiftUI

struct AnimatedIcon: View {
    @State private var isAnimating = false
    
    var body: some View {
        Image(isAnimating ? "uninstall_animated" : "uninstall")
            .resizable()
            .scaledToFit()
            .frame(width: 60, height: 60)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                    isAnimating.toggle()
                }
            }
    }
} 