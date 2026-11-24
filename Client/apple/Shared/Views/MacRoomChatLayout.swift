#if os(macOS)
import SwiftUI

/// Keep the transcript mounted at its final width. Only the panel's offset
/// animates; resizing a native inspector also animates the room's adaptive grid,
/// text wrapping and glass controls during every intermediate layout.
struct MacRoomChatLayout<RoomContent: View, ChatContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomNeedsVerification) private var needsVerification
    let isPresented: Bool
    @ViewBuilder var room: RoomContent
    @ViewBuilder var chat: ChatContent

    var body: some View {
        GeometryReader { geometry in
            let chatWidth = min(320, max(280, geometry.size.width - 380))
            let roomWidth = max(0, geometry.size.width - (isPresented ? chatWidth : 0))

            room
                .frame(width: roomWidth, height: geometry.size.height)
                .transaction(value: isPresented) {
                    // Lay out the room once, without interpolating grid columns
                    // or inheriting the chat panel's presentation animation.
                    $0.animation = nil
                    $0.disablesAnimations = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // The room resizes before the panel slides in. Paint the exposed
                // space throughout the transition instead of revealing the host.
                .background(needsVerification ? ChirpTheme.roomVerificationCanvas : ChirpTheme.canvas)
                .overlay(alignment: .trailing) {
                    chat
                        .frame(width: chatWidth, height: geometry.size.height)
                        .background(needsVerification ? ChirpTheme.roomVerificationCanvas : ChirpTheme.chatCanvas)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(ChirpTheme.border).frame(width: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .offset(x: isPresented ? 0 : chatWidth)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isPresented)
                        .disabled(!isPresented)
                        .allowsHitTesting(isPresented)
                        .accessibilityHidden(!isPresented)
                }
                .clipped()
        }
    }
}
#endif
