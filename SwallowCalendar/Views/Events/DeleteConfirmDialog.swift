//
//  DeleteConfirmDialog.swift
//  SwallowCalendar
//

import SwiftUI

struct DeleteConfirmDialog: View {
    let eventTitle: String
    let isRecurring: Bool
    let onConfirm: () -> Void
    let onDeleteAll: (() -> Void)?
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("确认删除")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }

            // 消息
            if isRecurring {
                Text("确定要删除事件「\(eventTitle)」吗？\n此操作无法撤销。\n\n这是周期任务，您可以选择只删除此项，或删除所有未完成的实例。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("确定要删除事件「\(eventTitle)」吗？\n此操作无法撤销。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 按钮
            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

                Button("删除此项") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                if isRecurring, let onDeleteAll = onDeleteAll {
                    Button("删除全部") {
                        onDeleteAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .background(Color.red.opacity(0.1))
                }
            }
        }
        .padding(20)
        .frame(width: isRecurring ? 350 : 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
