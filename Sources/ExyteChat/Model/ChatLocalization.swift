//
//  ChatLocalization.swift
//  Chat
//
//  Created by Aman Kumar on 18/12/24.
//

import Foundation

public struct ChatLocalization: Hashable, Sendable {
    public var inputPlaceholder: String
    public var signatureText: String
    public var cancelButtonText: String
    public var recentToggleText: String
    public var waitingForNetwork: String
    public var recordingText: String
    public var replyToText: String
    public var attachMediaText: String
    public var attachGifText: String
    public var attachCameraText: String
    public var attachDocumentText: String
    public var attachLocationText: String
    public var sendLocationText: String
    public var shareLiveLocationText: String
    public var stopSharingLocationText: String
    public var liveLocationText: String
    public var liveLocationEndedText: String
    public var liveLocationUpdatedJustNowText: String
    /// Format string with a single `%d` placeholder for the number of minutes, e.g. "updated %d min ago"
    public var liveLocationUpdatedMinutesAgoFormat: String
    public var openInMapsText: String
    public var openDocumentText: String

    public init(
        inputPlaceholder: String,
        signatureText: String,
        cancelButtonText: String,
        recentToggleText: String,
        waitingForNetwork: String,
        recordingText: String,
        replyToText: String,
        attachMediaText: String = String(localized: "Media"),
        attachGifText: String = String(localized: "GIF"),
        attachCameraText: String = String(localized: "Camera"),
        attachDocumentText: String = String(localized: "Document"),
        attachLocationText: String = String(localized: "Location"),
        sendLocationText: String = String(localized: "Send this location"),
        shareLiveLocationText: String = String(localized: "Share Live Location"),
        stopSharingLocationText: String = String(localized: "Stop Sharing"),
        liveLocationText: String = String(localized: "Live Location"),
        liveLocationEndedText: String = String(localized: "Live location ended"),
        liveLocationUpdatedJustNowText: String = String(localized: "updated just now"),
        liveLocationUpdatedMinutesAgoFormat: String = String(localized: "updated %d min ago"),
        openInMapsText: String = String(localized: "Open in Maps"),
        openDocumentText: String = String(localized: "Open")
    ) {
        self.inputPlaceholder = inputPlaceholder
        self.signatureText = signatureText
        self.cancelButtonText = cancelButtonText
        self.recentToggleText = recentToggleText
        self.waitingForNetwork = waitingForNetwork
        self.recordingText = recordingText
        self.replyToText = replyToText
        self.attachMediaText = attachMediaText
        self.attachGifText = attachGifText
        self.attachCameraText = attachCameraText
        self.attachDocumentText = attachDocumentText
        self.attachLocationText = attachLocationText
        self.sendLocationText = sendLocationText
        self.shareLiveLocationText = shareLiveLocationText
        self.stopSharingLocationText = stopSharingLocationText
        self.liveLocationText = liveLocationText
        self.liveLocationEndedText = liveLocationEndedText
        self.liveLocationUpdatedJustNowText = liveLocationUpdatedJustNowText
        self.liveLocationUpdatedMinutesAgoFormat = liveLocationUpdatedMinutesAgoFormat
        self.openInMapsText = openInMapsText
        self.openDocumentText = openDocumentText
    }

   public static var defaultLocalization: ChatLocalization {
        ChatLocalization(
            inputPlaceholder: String(localized: "Type a message..."),
            signatureText: String(localized: "Add signature..."),
            cancelButtonText: String(localized: "Cancel"),
            recentToggleText: String(localized: "Recents"),
            waitingForNetwork: String(localized: "Waiting for network"),
            recordingText: String(localized: "Recording..."),
            replyToText: String(localized: "Reply to"),
            attachMediaText: String(localized: "Media"),
            attachGifText: String(localized: "GIF"),
            attachCameraText: String(localized: "Camera"),
            attachDocumentText: String(localized: "Document"),
            attachLocationText: String(localized: "Location"),
            sendLocationText: String(localized: "Send this location"),
            shareLiveLocationText: String(localized: "Share Live Location"),
            stopSharingLocationText: String(localized: "Stop Sharing"),
            liveLocationText: String(localized: "Live Location"),
            liveLocationEndedText: String(localized: "Live location ended"),
            liveLocationUpdatedJustNowText: String(localized: "updated just now"),
            liveLocationUpdatedMinutesAgoFormat: String(localized: "updated %d min ago"),
            openInMapsText: String(localized: "Open in Maps"),
            openDocumentText: String(localized: "Open")
        )
    }

    /// Complete Simplified Chinese copy for all built-in chat surfaces.
    public static var simplifiedChinese: ChatLocalization {
        ChatLocalization(
            inputPlaceholder: "发送消息",
            signatureText: "添加说明",
            cancelButtonText: "取消",
            recentToggleText: "最近项目",
            waitingForNetwork: "正在等待网络",
            recordingText: "正在录音…",
            replyToText: "回复",
            attachMediaText: "照片与视频",
            attachGifText: "GIF",
            attachCameraText: "相机",
            attachDocumentText: "文件",
            attachLocationText: "位置",
            sendLocationText: "发送此位置",
            shareLiveLocationText: "共享实时位置",
            stopSharingLocationText: "停止共享",
            liveLocationText: "实时位置",
            liveLocationEndedText: "实时位置共享已结束",
            liveLocationUpdatedJustNowText: "刚刚更新",
            liveLocationUpdatedMinutesAgoFormat: "%d 分钟前更新",
            openInMapsText: "在地图中打开",
            openDocumentText: "打开文件"
        )
    }
}
