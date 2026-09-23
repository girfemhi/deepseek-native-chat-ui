//
//  UIList+RowUpdates.swift
//  Chat
//
//  Created by OpenAI on 23.09.2026.
//

import Foundation

/// A cheap update plan for streaming message edits.  It is deliberately
/// conservative: anything that can change UITableView's row topology falls
/// back to the existing structural diff/reload paths.
struct RowUpdatePlan: Equatable {
    let changedIndexPaths: [IndexPath]

    static func make(
        oldSections: [MessagesSection],
        newSections: [MessagesSection],
        showsLastReadIndicator: Bool
    ) -> RowUpdatePlan? {
        guard oldSections.count == newSections.count else { return nil }

        let oldIndicator = lastReadIndicatorIndexPath(
            sections: oldSections,
            enabled: showsLastReadIndicator
        )
        let newIndicator = lastReadIndicatorIndexPath(
            sections: newSections,
            enabled: showsLastReadIndicator
        )
        guard oldIndicator == newIndicator else { return nil }

        var changedIndexPaths: [IndexPath] = []

        for sectionIndex in oldSections.indices {
            let oldSection = oldSections[sectionIndex]
            let newSection = newSections[sectionIndex]

            guard oldSection.date == newSection.date,
                  oldSection.rows.count == newSection.rows.count else {
                return nil
            }

            for rowIndex in oldSection.rows.indices {
                let oldRow = oldSection.rows[rowIndex]
                let newRow = newSection.rows[rowIndex]
                guard oldRow.id == newRow.id else { return nil }

                if oldRow != newRow {
                    let tableRow: Int
                    if let indicator = newIndicator,
                       indicator.section == sectionIndex,
                       rowIndex >= indicator.row {
                        tableRow = rowIndex + 1
                    } else {
                        tableRow = rowIndex
                    }
                    changedIndexPaths.append(IndexPath(row: tableRow, section: sectionIndex))
                }
            }
        }

        return RowUpdatePlan(changedIndexPaths: changedIndexPaths)
    }

    private static func lastReadIndicatorIndexPath(
        sections: [MessagesSection],
        enabled: Bool
    ) -> IndexPath? {
        guard enabled else { return nil }
        for (sectionIndex, section) in sections.enumerated() {
            for (rowIndex, row) in section.rows.enumerated() {
                if case .readBy = row.message.status,
                   sectionIndex > 0 || rowIndex > 0 {
                    return IndexPath(row: rowIndex, section: sectionIndex)
                }
            }
        }
        return nil
    }
}
