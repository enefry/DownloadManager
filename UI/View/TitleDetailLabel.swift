//
//  TitleDetailLabel.swift
//  DownloadManager
//
//  Created by chen on 2025/6/30.
//

import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

struct TitleDetailLabel: View {
    var title: String
    var detail: String
    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(detail)
                .font(.caption.monospaced())
        }
    }
}
