//
//  ContentView.swift
//  FirstContact
//
//  Created by Vincent Wong on 4/26/26.
//

import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.40, green: 0.494, blue: 0.918), // #667eea
                    Color(red: 0.463, green: 0.294, blue: 0.635) // #764ba2
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                Text("Hello, World!")
                    .font(.system(size: 48, weight: .bold))
                Text("You are on: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    .font(.system(size: 20))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
