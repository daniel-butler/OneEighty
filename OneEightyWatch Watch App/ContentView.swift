//
//  ContentView.swift
//  OneEightyWatch Watch App
//
//  Created by Daniel Butler on 3/12/26.
//

import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager()

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            // SPM display
            Text("\(session.bpm)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .foregroundStyle(session.isCoolingDown ? .secondary : .primary)
                .animation(.easeInOut(duration: 0.15), value: session.isCoolingDown)
                .accessibilityIdentifier("bpmDisplay")
            Text("SPM")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Controls: minus, toggle, plus
            HStack(spacing: 12) {
                Button {
                    session.decrementBPM()
                } label: {
                    Image(systemName: "minus")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("decrementBPM")

                Button {
                    session.toggle()
                } label: {
                    Image(systemName: session.isPlaying ? "stop.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(session.isPlaying ? .red : .green)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("togglePlayback")

                Button {
                    session.incrementBPM()
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("incrementBPM")
            }

            // Connection status
            if !session.isReachable {
                Text("Phone not connected")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
        .onAppear {
            session.activate()
        }
    }
}

#Preview {
    ContentView()
}
