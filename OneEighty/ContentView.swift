//
//  ContentView.swift
//  OneEighty
//
//  Created by Daniel Butler on 12/21/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: "app.rekuro.OneEighty", category: "ContentView")

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    var engine: OneEightyEngine
    @State private var showBPMAlert: Bool = false
    @State private var bpmText: String = ""
    @State private var showSPMInfo: Bool = false

    var body: some View {
        VStack(spacing: 40) {
            SextantCard()
                .padding(.horizontal, 40)
                .padding(.top, 8)

            Spacer()

            // BPM Display
            VStack(spacing: 4) {
                Text("\(engine.bpm)")
                    .font(.system(size: 116, weight: .black))
                    .foregroundStyle(OE.ascent)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: engine.bpm)
                    .accessibilityIdentifier("bpmDisplay")
                    .onTapGesture {
                        bpmText = "\(engine.bpm)"
                        showBPMAlert = true
                    }
                HStack(spacing: 6) {
                    Text("SPM")
                        .font(.system(.subheadline, design: .default, weight: .semibold))
                        .tracking(3)
                    Button {
                        showSPMInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What does SPM mean?")
                    .popover(isPresented: $showSPMInfo) {
                        SPMInfoBubble()
                            .presentationCompactAdaptation(.popover)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .alert("Set SPM", isPresented: $showBPMAlert) {
                TextField("150–230", text: $bpmText)
                    .keyboardType(.numberPad)
                Button("OK") { commitBPM() }
                Button("Cancel", role: .cancel) { }
            }

            // BPM Controls
            HStack(spacing: 48) {
                Button {
                    engine.decrementBPM()
                } label: {
                    Image(systemName: "minus")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(OE.accent)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .stroke(OE.accent, lineWidth: 2)
                        )
                }
                .disabled(!engine.canDecrementBPM)
                .accessibilityIdentifier("decrementBPM")

                Button {
                    engine.incrementBPM()
                } label: {
                    Image(systemName: "plus")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(OE.accent)
                        .frame(width: 60, height: 60)
                        .background(
                            Circle()
                                .stroke(OE.accent, lineWidth: 2)
                        )
                }
                .disabled(!engine.canIncrementBPM)
                .accessibilityIdentifier("incrementBPM")
            }

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
                    .fontWeight(.bold)
                    .tracking(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background {
                        if engine.isPlaying { OE.stop }
                        else { OE.ascent }
                    }
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityIdentifier("togglePlayback")
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .tint(OE.accent)
        .onAppear {
            logger.info("onAppear — hydrating engine for UI launch")
            engine.hydrateForUILaunch()
        }
    }

    private func commitBPM() {
        guard let typed = Int(bpmText) else { return }
        engine.setBPM(typed)
    }
}

/// Small popover explaining the SPM label.
private struct SPMInfoBubble: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steps per minute")
                .font(.subheadline.weight(.semibold))
            Text("Your running cadence: how often your feet hit the ground. Around 180 is a common target.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 240)
    }
}

#Preview {
    ContentView(engine: OneEightyEngine())
}
