//
//  ChatTheme.swift
//
//
//  Created by Alisa Mylnikova on 31.01.2023.
//

import SwiftUI

public extension EnvironmentValues {
    #if swift(>=6.0)
    @Entry var chatTheme = ChatTheme()
    @Entry var giphyConfig = GiphyConfiguration()
    @Entry var chatLocalization = ChatLocalization.defaultLocalization
    #else
    var chatTheme: ChatTheme {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }

    var giphyConfig: GiphyConfiguration {
        get { self[GiphyConfigurationKey.self] }
        set { self[GiphyConfigurationKey.self] = newValue }
    }

    var chatLocalization: ChatLocalization {
        get { self[ChatLocalizationKey.self] }
        set { self[ChatLocalizationKey.self] = newValue }
    }
    #endif
}

// Define keys only for older versions
#if swift(<6.0)
@preconcurrency public struct ChatThemeKey: EnvironmentKey {
    public static let defaultValue = ChatTheme()
}

public struct GiphyConfigurationKey: EnvironmentKey {
    public static let defaultValue = GiphyConfiguration()
}

public struct ChatLocalizationKey: EnvironmentKey {
    public static let defaultValue = ChatLocalization.defaultLocalization
}
#endif

extension View {

    public func chatTheme(_ theme: ChatTheme) -> some View {
        self.environment(\.chatTheme, theme)
    }

    public func chatTheme(
        colors: ChatTheme.Colors = .init(),
        images: ChatTheme.Images = .init()
    ) -> some View {
        self.environment(\.chatTheme, ChatTheme(colors: colors, images: images))
    }

    public func giphyConfig(_ config: GiphyConfiguration) -> some View {
        self.environment(\.giphyConfig, config)
    }
}

public struct ChatTheme: Sendable {
    public let colors: ChatTheme.Colors
    public let images: ChatTheme.Images
    public let style: ChatTheme.Style

    public var contentBG: Color {
        images.background != nil ? .clear : colors.mainBG
    }

    public init(
        colors: ChatTheme.Colors = .init(),
        images: ChatTheme.Images = .init(),
        style: ChatTheme.Style = .init()
    ) {
        self.style = style
        self.images = images
        self.colors = colors
    }
    
    internal init(accentColor: Color, images: ChatTheme.Images) {
        self.init(
            colors: .init(
                mainTint: accentColor,
                messageMyBG: accentColor,
                messageMyTimeText: Color.white.opacity(0.5),
                sendButtonBackground: accentColor
            ),
            images: images
        )
    }
    
    @available(iOS 18.0, *)
    internal init(accentColor: Color, background: ThemedBackgroundStyle = .mixedWithAccentColor(), improveContrast: Bool) {
        let backgroundColor: Color = background.getBackgroundColor(withAccent: accentColor, improveContrast: improveContrast)
        let friendMessageColor: Color = background.getFriendMessageColor(improveContrast: improveContrast, background: backgroundColor)
        self.init(
            colors: .init(
                mainBG: backgroundColor,
                mainTint: accentColor,
                messageMyBG: accentColor,
                messageMyText: Color.white,
                messageMyTimeText: Color.white.opacity(0.5),
                messageFriendBG: friendMessageColor,
                inputBG: friendMessageColor,
                menuBG: backgroundColor,
                sendButtonBackground: accentColor
            )
        )
    }

    public struct Colors: Sendable {
        public var mainBG: Color
        public var mainTint: Color
        public var mainText: Color
        public var mainCaptionText: Color

        public var messageMyBG: Color
        public var messageMyText: Color
        public var messageMyTimeText: Color
        public var messageReadStatus: Color

        public var messageFriendBG: Color
        public var messageFriendText: Color
        public var messageFriendTimeText: Color
        
        public var messageSystemBG: Color
        public var messageSystemText: Color
        public var messageSystemTimeText: Color

        public var inputBG: Color
        public var inputText: Color
        public var inputPlaceholderText: Color

        public var inputSignatureBG: Color
        public var inputSignatureText: Color
        public var inputSignaturePlaceholderText: Color

        public var menuBG: Color
        public var menuText: Color
        public var menuTextDelete: Color

        public var statusError: Color
        public var statusGray: Color

        public var sendButtonBackground: Color
        public var recordDot: Color

        public init(
            mainBG: Color = ChatPortableColors.mainBG,
            mainTint: Color = ChatPortableColors.inputPlaceholderText,
            mainText: Color = ChatPortableColors.mainText,
            mainCaptionText: Color = ChatPortableColors.mainCaptionText,
            messageMyBG: Color = ChatPortableColors.messageMyBG,
            messageReadStatus: Color = ChatPortableColors.messageReadStatus,
            messageMyText: Color = Color.white,
            messageMyTimeText: Color = ChatPortableColors.messageMyTimeText,
            messageFriendBG: Color = ChatPortableColors.messageFriendBG,
            messageFriendText: Color = ChatPortableColors.mainText,
            messageFriendTimeText: Color = ChatPortableColors.messageFriendTimeText,
            messageSystemBG: Color = ChatPortableColors.messageFriendBG,
            messageSystemText: Color = ChatPortableColors.mainText,
            messageSystemTimeText: Color = ChatPortableColors.messageFriendTimeText,
            inputBG: Color = ChatPortableColors.inputBG,
            inputText: Color = ChatPortableColors.mainText,
            inputPlaceholderText: Color = ChatPortableColors.inputPlaceholderText,
            inputSignatureBG: Color = ChatPortableColors.inputBG,
            inputSignatureText: Color = ChatPortableColors.mainText,
            inputSignaturePlaceholderText: Color = ChatPortableColors.inputPlaceholderText,
            menuBG: Color = ChatPortableColors.menuBG,
            menuText: Color = ChatPortableColors.menuText,
            menuTextDelete: Color = ChatPortableColors.menuTextDelete,
            statusError: Color = ChatPortableColors.statusError,
            statusGray: Color = ChatPortableColors.statusGray,
            sendButtonBackground: Color = ChatPortableColors.messageMyBG,
            recordDot: Color = ChatPortableColors.menuTextDelete
        ) {
            self.mainBG = mainBG
            self.mainTint = mainTint
            self.mainText = mainText
            self.mainCaptionText = mainCaptionText
            self.messageMyBG = messageMyBG
            self.messageMyText = messageMyText
            self.messageReadStatus = messageReadStatus
            self.messageMyTimeText = messageMyTimeText
            self.messageFriendBG = messageFriendBG
            self.messageFriendText = messageFriendText
            self.messageFriendTimeText = messageFriendTimeText
            self.messageSystemBG = messageSystemBG
            self.messageSystemText = messageSystemText
            self.messageSystemTimeText = messageSystemTimeText
            self.inputBG = inputBG
            self.inputText = inputText
            self.inputPlaceholderText = inputPlaceholderText
            self.inputSignatureBG = inputSignatureBG
            self.inputSignatureText = inputSignatureText
            self.inputSignaturePlaceholderText = inputSignaturePlaceholderText
            self.menuBG = menuBG
            self.menuText = menuText
            self.menuTextDelete = menuTextDelete
            self.statusError = statusError
            self.statusGray = statusGray
            self.sendButtonBackground = sendButtonBackground
            self.recordDot = recordDot
        }
        
        public init(copy: Colors, mainBG: Color) {
            self.mainBG = mainBG
            self.mainTint = copy.mainTint
            self.mainText = copy.mainText
            self.mainCaptionText = copy.mainCaptionText
            self.messageMyBG = copy.messageMyBG
            self.messageMyText = copy.messageMyText
            self.messageReadStatus = copy.messageReadStatus
            self.messageMyTimeText = copy.messageMyTimeText
            self.messageFriendBG = copy.messageFriendBG
            self.messageFriendText = copy.messageFriendText
            self.messageFriendTimeText = copy.messageFriendTimeText
            self.messageSystemBG = copy.messageSystemBG
            self.messageSystemText = copy.messageSystemText
            self.messageSystemTimeText = copy.messageSystemTimeText
            self.inputBG = copy.inputBG
            self.inputText = copy.inputText
            self.inputPlaceholderText = copy.inputPlaceholderText
            self.inputSignatureBG = copy.inputSignatureBG
            self.inputSignatureText = copy.inputSignatureText
            self.inputSignaturePlaceholderText = copy.inputSignaturePlaceholderText
            self.menuBG = copy.menuBG
            self.menuText = copy.menuText
            self.menuTextDelete = copy.menuTextDelete
            self.statusError = copy.statusError
            self.statusGray = copy.statusGray
            self.sendButtonBackground = copy.sendButtonBackground
            self.recordDot = copy.recordDot
        }
    }

    public struct Images: Sendable {
      
        public struct Background: Sendable {
            
            let safeAreaRegions: SafeAreaRegions
            let safeAreaEdges: Edge.Set
            let portraitBackgroundLight: Image
            let portraitBackgroundDark: Image
            let landscapeBackgroundLight: Image
            let landscapeBackgroundDark: Image

            public init(
                safeAreaRegions: SafeAreaRegions = .all,
                safeAreaEdges: Edge.Set = .all,
                portraitBackgroundLight: Image,
                portraitBackgroundDark: Image,
                landscapeBackgroundLight: Image,
                landscapeBackgroundDark: Image
            ) {
                self.safeAreaRegions = safeAreaRegions
                self.safeAreaEdges = safeAreaEdges
                self.portraitBackgroundLight = portraitBackgroundLight
                self.portraitBackgroundDark = portraitBackgroundDark
                self.landscapeBackgroundLight = landscapeBackgroundLight
                self.landscapeBackgroundDark = landscapeBackgroundDark
            }
        }

        public struct AttachMenu: Sendable {
            public var camera: Image
            public var contact: Image
            public var document: Image
            public var location: Image
            public var photo: Image
            public var pickDocument: Image
            public var pickLocation: Image
            public var pickPhoto: Image
        }

        public struct InputView: Sendable {
            public var add: Image
            public var arrowSend: Image
            public var sticker: Image
            public var attach: Image
            public var attachCamera: Image
            public var microphone: Image
            public var clearText: Image
        }

        public struct FullscreenMedia: Sendable {
            public var play: Image
            public var pause: Image
            public var mute: Image
            public var unmute: Image
            public var share: Image
        }

        public struct MediaPicker: Sendable {
            public var chevronDown: Image
            public var chevronRight: Image
            public var cross: Image
        }

        public struct Message: Sendable {
            public var attachedDocument: Image
            public var cancel: Image
            public var error: Image
            public var muteVideo: Image
            public var pauseAudio: Image
            public var pauseVideo: Image
            public var playAudio: Image
            public var playVideo: Image
            public var read: Image
            public var sending: Image
            public var delivered: Image
            public var sent: Image
        }

        public struct MessageMenu: Sendable {
            public var delete: Image
            public var edit: Image
            public var forward: Image
            public var retry: Image
            public var save: Image
            public var select: Image
        }

        public struct RecordAudio: Sendable {
            public var cancelRecord: Image
            public var deleteRecord: Image
            public var lockRecord: Image
            public var pauseRecord: Image
            public var playRecord: Image
            public var sendRecord: Image
            public var stopRecord: Image
        }

        public struct Reply: Sendable {
            public var cancelReply: Image
            public var replyToMessage: Image
        }
      
        public var background: Background? = nil
  
        public var backButton: Image
        public var scrollToBottom: Image

        public var attachMenu: AttachMenu
        public var inputView: InputView
        public var fullscreenMedia: FullscreenMedia
        public var mediaPicker: MediaPicker
        public var message: Message
        public var messageMenu: MessageMenu
        public var recordAudio: RecordAudio
        public var reply: Reply

        public init(
            camera: Image? = nil,
            contact: Image? = nil,
            document: Image? = nil,
            location: Image? = nil,
            photo: Image? = nil,
            pickDocument: Image? = nil,
            pickLocation: Image? = nil,
            pickPhoto: Image? = nil,
            add: Image? = nil,
            arrowSend: Image? = nil,
            sticker: Image? = nil,
            attach: Image? = nil,
            attachCamera: Image? = nil,
            microphone: Image? = nil,
            clearText: Image? = nil,
            fullscreenPlay: Image? = nil,
            fullscreenPause: Image? = nil,
            fullscreenMute: Image? = nil,
            fullscreenUnmute: Image? = nil,
            fullscreenShare: Image? = nil,
            chevronDown: Image? = nil,
            chevronRight: Image? = nil,
            cross: Image? = nil,
            attachedDocument: Image? = nil,
            cancel: Image? = nil,
            error: Image? = nil,
            muteVideo: Image? = nil,
            pauseAudio: Image? = nil,
            pauseVideo: Image? = nil,
            playAudio: Image? = nil,
            playVideo: Image? = nil,
            read: Image? = nil,
            sending: Image? = nil,
            delivered: Image? = nil,
            sent: Image? = nil,
            delete: Image? = nil,
            edit: Image? = nil,
            forward: Image? = nil,
            retry: Image? = nil,
            save: Image? = nil,
            select: Image? = nil,
            cancelRecord: Image? = nil,
            deleteRecord: Image? = nil,
            lockRecord: Image? = nil,
            pauseRecord: Image? = nil,
            playRecord: Image? = nil,
            sendRecord: Image? = nil,
            stopRecord: Image? = nil,
            cancelReply: Image? = nil,
            replyToMessage: Image? = nil,
            backButton: Image? = nil,
            scrollToBottom: Image? = nil,
            background: Background? = nil
        ) {
            self.backButton = backButton ?? ChatPortableImages.image("backArrow", fallback: "chevron.left", template: true)
            self.scrollToBottom = scrollToBottom ?? Image(systemName: "chevron.down")
            
            self.background = background

            self.attachMenu = AttachMenu(
                camera: camera ?? ChatPortableImages.image("camera", fallback: "camera.fill"),
                contact: contact ?? ChatPortableImages.image("contact", fallback: "person.crop.circle"),
                document: document ?? ChatPortableImages.image("document", fallback: "doc.fill"),
                location: location ?? ChatPortableImages.image("location", fallback: "location.fill"),
                photo: photo ?? ChatPortableImages.image("photo", fallback: "photo.fill"),
                pickDocument: pickDocument ?? ChatPortableImages.image("pickDocument", fallback: "doc"),
                pickLocation: pickLocation ?? ChatPortableImages.image("pickLocation", fallback: "location"),
                pickPhoto: pickPhoto ?? ChatPortableImages.image("pickPhoto", fallback: "photo")
            )

            self.inputView = InputView(
                add: add ?? ChatPortableImages.image("add", fallback: "plus"),
                arrowSend: arrowSend ?? ChatPortableImages.image("arrowSend", fallback: "arrow.up"),
                sticker: sticker ?? ChatPortableImages.image("sticker", fallback: "face.smiling"),
                attach: attach ?? ChatPortableImages.image("attach", fallback: "paperclip"),
                attachCamera: attachCamera ?? ChatPortableImages.image("attachCamera", fallback: "camera"),
                microphone: microphone ?? ChatPortableImages.image("microphone", fallback: "mic.fill"),
                clearText: clearText ?? Image(systemName: "xmark.circle.fill")
            )

            self.fullscreenMedia = FullscreenMedia(
                play: fullscreenPlay ?? Image(systemName: "play.fill"),
                pause: fullscreenPause ?? Image(systemName: "pause.fill"),
                mute: fullscreenMute ?? Image(systemName: "speaker.slash.fill"),
                unmute: fullscreenUnmute ?? Image(systemName: "speaker.fill"),
                share: fullscreenShare ?? Image(systemName: "square.and.arrow.up")
            )

            self.mediaPicker = MediaPicker(
                chevronDown: chevronDown ?? ChatPortableImages.image("chevronDown", fallback: "chevron.down"),
                chevronRight: chevronRight ?? ChatPortableImages.image("chevronRight", fallback: "chevron.right"),
                cross: cross ?? Image(systemName: "xmark")
            )

            self.message = Message(
                attachedDocument: attachedDocument ?? ChatPortableImages.image("attachedDocument", fallback: "doc.fill"),
                cancel: cancel ?? Image(systemName: "xmark.circle.fill"),
                error: error ?? Image(systemName: "exclamationmark.circle.fill"),
                muteVideo: muteVideo ?? ChatPortableImages.image("MuteVideo", fallback: "speaker.slash.fill"),
                pauseAudio: pauseAudio ?? ChatPortableImages.image("pauseAudio", fallback: "pause.fill"),
                pauseVideo: pauseVideo ?? Image(systemName: "pause.circle.fill"),
                playAudio: playAudio ?? ChatPortableImages.image("playAudio", fallback: "play.fill"),
                playVideo: playVideo ?? Image(systemName: "play.circle.fill"),
                read: read ?? Image(systemName: "checkmark"),
                sending: sending ?? Image(systemName: "clock"),
                delivered: delivered ?? Image(systemName: "checkmark"),
                sent: sent ?? Image(systemName: "checkmark")
            )

            self.messageMenu = MessageMenu(
                delete: delete ?? ChatPortableImages.image("delete", fallback: "trash"),
                edit: edit ?? ChatPortableImages.image("edit", fallback: "square.and.pencil"),
                forward: forward ?? ChatPortableImages.image("forward", fallback: "arrowshape.turn.up.right"),
                retry: retry ?? ChatPortableImages.image("retry", fallback: "arrow.clockwise"),
                save: save ?? ChatPortableImages.image("save", fallback: "square.and.arrow.down"),
                select: select ?? ChatPortableImages.image("select", fallback: "checkmark.circle")
            )

            self.recordAudio = RecordAudio(
                cancelRecord: cancelRecord ?? ChatPortableImages.image("cancelRecord", fallback: "chevron.left"),
                deleteRecord: deleteRecord ?? ChatPortableImages.image("deleteRecord", fallback: "trash"),
                lockRecord: lockRecord ?? ChatPortableImages.image("lockRecord", fallback: "lock.fill"),
                pauseRecord: pauseRecord ?? Image(systemName: "pause.fill"),
                playRecord: playRecord ?? Image(systemName: "play.fill"),
                sendRecord: sendRecord ?? ChatPortableImages.image("sendRecord", fallback: "arrow.up"),
                stopRecord: stopRecord ?? ChatPortableImages.image("stopRecord", fallback: "stop.fill")
            )

            self.reply = Reply(
                cancelReply: cancelReply ?? Image(systemName: "x.circle"),
                replyToMessage: replyToMessage ?? Image(systemName: "arrow.uturn.left")
            )
        }
    }
    
    public struct Style: Sendable {
        public var replyOpacity: Double
        
        public init(replyOpacity: Double = 0.8) {
            self.replyOpacity = replyOpacity
        }
    }
}

public extension ChatTheme {
    /// A semantic light/dark theme for agent clients with a restrained indigo accent.
    static var agentDefault: ChatTheme {
        let accent = Color.indigo
        return ChatTheme(
            colors: .init(
                mainBG: Color(uiColor: .systemBackground),
                mainTint: accent,
                mainText: Color(uiColor: .label),
                mainCaptionText: Color(uiColor: .secondaryLabel),
                messageMyBG: accent,
                messageReadStatus: accent.opacity(0.75),
                messageMyText: .white,
                messageMyTimeText: .white.opacity(0.68),
                messageFriendBG: Color(uiColor: .secondarySystemBackground),
                messageFriendText: Color(uiColor: .label),
                messageFriendTimeText: Color(uiColor: .secondaryLabel),
                messageSystemBG: Color(uiColor: .tertiarySystemBackground),
                messageSystemText: Color(uiColor: .label),
                messageSystemTimeText: Color(uiColor: .secondaryLabel),
                inputBG: Color(uiColor: .secondarySystemBackground),
                inputText: Color(uiColor: .label),
                inputPlaceholderText: Color(uiColor: .placeholderText),
                inputSignatureBG: Color(uiColor: .secondarySystemBackground),
                inputSignatureText: Color(uiColor: .label),
                inputSignaturePlaceholderText: Color(uiColor: .placeholderText),
                menuBG: Color(uiColor: .secondarySystemBackground),
                menuText: Color(uiColor: .label),
                menuTextDelete: .red,
                statusError: .red,
                statusGray: Color(uiColor: .secondaryLabel),
                sendButtonBackground: accent,
                recordDot: .red
            )
        )
    }
}
