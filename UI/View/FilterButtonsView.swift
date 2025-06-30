//
//  FilterButtonsView.swift
//  DownloadManager
//
//  Created by chen on 2025/6/29.
//


import Combine
import DownloadManager
import DownloadManagerBasic
import SwiftUI

 struct FilterButtonsView: View {
    @Binding var selectedFilter: DownloadStateFilter

    var body: some View {
        Picker("", selection: $selectedFilter) {
            ForEach(DownloadStateFilter.cases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }
}
