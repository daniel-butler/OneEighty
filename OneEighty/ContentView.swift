//
//  ContentView.swift
//  OneEighty
//
//  Created by Daniel Butler on 12/21/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "com.danielbutler.OneEighty", category: "ContentView")

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    var engine: OneEightyEngine
    @State private var showBPMAlert: Bool = false
    @State private var bpmText: String = ""

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            // BPM Display
            VStack(spacing: 8) {
                Text("\(engine.bpm)")
                    .font(.system(size: 80, weight: .bold))
                    .accessibilityIdentifier("bpmDisplay")
                    .onTapGesture {
                        bpmText = "\(engine.bpm)"
                        showBPMAlert = true
                    }
                Text("SPM")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .alert("Set SPM", isPresented: $showBPMAlert) {
                TextField("150–230", text: $bpmText)
                    .keyboardType(.numberPad)
                Button("OK") { commitBPM() }
                Button("Cancel", role: .cancel) { }
            }

            // BPM Controls
            HStack(spacing: 60) {
                Button {
                    engine.decrementBPM()
                } label: {
                    Image(systemName: "minus")
                        .font(.title)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .stroke(lineWidth: 2)
                        )
                }
                .disabled(!engine.canDecrementBPM)
                .accessibilityIdentifier("decrementBPM")

                Spacer()

                Button {
                    engine.incrementBPM()
                } label: {
                    Image(systemName: "plus")
                        .font(.title)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .stroke(lineWidth: 2)
                        )
                }
                .disabled(!engine.canIncrementBPM)
                .accessibilityIdentifier("incrementBPM")
            }
            .padding(.horizontal, 40)

            Spacer()

            // Volume Control
            HStack(spacing: 16) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)

                Slider(value: Binding(
                    get: { Double(engine.volume) },
                    set: { engine.setVolume(Float($0)) }
                ), in: 0...1)
            }
            .padding(.horizontal, 40)

            // Start/Stop Button
            Button {
                engine.togglePlayback()
            } label: {
                Text(engine.isPlaying ? "STOP" : "START")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(engine.isPlaying ? Color.red : Color.blue)
                    .foregroundStyle(.white)
                    .cornerRadius(12)
            }
            .accessibilityIdentifier("togglePlayback")
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .onAppear {
            logger.info("onAppear — setting up engine")
            engine.setup()

            Task { @MainActor in
                LiveActivityManager.shared.cleanupStaleActivities()
                LiveActivityManager.shared.startActivity(bpm: engine.bpm, isPlaying: false)
            }
        }
        .onDisappear {
            logger.info("onDisappear — tearing down engine")
            engine.teardown()
        }
    }

    private func commitBPM() {
        guard let typed = Int(bpmText) else { return }
        engine.setBPM(typed)
    }
}

#Preview {
    ContentView(engine: OneEightyEngine())
}
