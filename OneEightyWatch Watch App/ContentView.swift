//
//  ContentView.swift
//  OneEightyWatch Watch App
//
//  Created by Daniel Butler on 3/12/26.
//

import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager()
    @State private var crownBPM: Double = 180
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            Spacer()

            // SPM display
            Text("\(session.bpm)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .foregroundStyle(session.hasPendingEdit ? .secondary : .primary)
                .animation(.easeInOut(duration: 0.15), value: session.hasPendingEdit)
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
        .focusable()
        .digitalCrownRotation(
            $crownBPM,
            from: Double(150),
            through: Double(230),
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownBPM) { _, newValue in
            let target = Int(newValue)
            let delta = target - session.bpm
            if delta > 0 {
                for _ in 0..<delta { session.incrementBPM() }
            } else if delta < 0 {
                for _ in 0..<(-delta) { session.decrementBPM() }
            }
        }
        .onChange(of: session.bpm) { _, newBPM in
            crownBPM = Double(newBPM)
        }
        .onAppear {
            session.activate()
            crownBPM = Double(session.bpm)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                session.activate()
            case .inactive, .background:
                session.flushAndInvalidateTimers()
            @unknown default:
                break
            }
        }
    }
}

#Preview {
    ContentView()
}
