//
//  Fomratter.swift
//  DownloadManager
//
//  Created by 陈任伟 on 2025/6/29.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

fileprivate let kMinuteSeconds: TimeInterval = 60
fileprivate let kHourSecond: TimeInterval = kMinuteSeconds * 60
fileprivate let kDaySeconds: TimeInterval = kHourSecond * 24

func format(time: TimeInterval) -> String {
    let day = Int(truncating: (time / kDaySeconds) as NSNumber)
    let daySecond = TimeInterval(day) * kDaySeconds
    let hour = Int(truncating: ((time - daySecond) / kHourSecond) as NSNumber)
    if day > 0 {
        return String(format: "%d,%02dH", day, hour)
    } else {
        // 不超过一天
        let hourSecond = TimeInterval(hour) * kHourSecond
        let minute = Int(truncating: ((time - daySecond - hourSecond) / kMinuteSeconds) as NSNumber)
        let minuteSecond = TimeInterval(minute) * kMinuteSeconds
        let second = Int(truncating: (time - daySecond - hourSecond - minuteSecond) as NSNumber)

        if hour > 1 {
            // 超过小时，不显示秒
            return String(format: "%02d:%02d:%02d", hour, minute)
        } else {
            if minute > 0 {
                return String(format: "%02d:%02d", minute, second)
            } else {
                return String(format: "%ds", second)
            }
        }
    }
}
