//
//  OneEightyWidget.swift
//  OneEightyWidget
//
//  Created by Claude on 12/23/25.
//

import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// Shared content view for the SPM toggle button center area
private struct SPMToggleContent: View {
    let bpm: Int
    let isPlaying: Bool
    let bpmFontSize: CGFloat
    let iconSize: CGFloat

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(isPlaying ? .red : .green)
                    .contentTransition(.identity)
                Text("\(bpm)")
                    .font(.system(size: bpmFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            Text("SPM")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

// The Live Activity widget
struct OneEightyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OneEightyActivityAttributes.self) { context in
            // Lock screen / banner UI
            HStack(spacing: 12) {
                // Minus button
                Button(intent: DecrementBPMIntent()) {
                    Image(systemName: "minus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                // Center: SPM display + play/stop toggle (single intent, visual changes with state)
                Button(intent: ToggleOneEightyIntent()) {
                    SPMToggleContent(bpm: context.state.bpm, isPlaying: context.state.isPlaying, bpmFontSize: 34, iconSize: 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(height: 72)

                // Plus button
                Button(intent: IncrementBPMIntent()) {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(Color.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // Use .bottom for full-width 3-button layout
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        // Minus button
                        Button(intent: DecrementBPMIntent()) {
                            Image(systemName: "minus")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        // Center: SPM display + play/stop toggle
                        Button(intent: ToggleOneEightyIntent()) {
                            SPMToggleContent(bpm: context.state.bpm, isPlaying: context.state.isPlaying, bpmFontSize: 26, iconSize: 13)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)

                        // Plus button
                        Button(intent: IncrementBPMIntent()) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .bold))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "figure.run")
                    .font(.system(size: 16))
            } compactTrailing: {
                Text("\(context.state.bpm)")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.numericText())
            } minimal: {
                Image(systemName: "figure.run")
                    .font(.system(size: 16))
            }
            .widgetURL(URL(string: "oneeighty://open"))
            .keylineTint(context.state.isPlaying ? .green : .gray)
        }
    }
}
