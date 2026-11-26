import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: ProxyModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportedLogURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section("프록시 카운터") {
                    LabeledContent("누적 처리 연결", value: "\(model.snapshot.totalConnectionsHandled)")
                    LabeledContent("상한 초과 거절", value: "\(model.snapshot.rejectedConnections)")
                    LabeledContent("아웃바운드 다이얼 실패", value: "\(model.snapshot.dialFailures)")
                    LabeledContent("리스너 자동 재오픈", value: "\(model.snapshot.listenerRestarts)")
                    LabeledContent("버퍼 / 연결 상한", value: "\(model.config.bufferSize / 1024) KB / \(model.config.maxConnections)")
                    LabeledContent("앱 버전", value: ProxyModel.appVersion)
                }

                Section {
                    Button("카운터 초기화", role: .destructive) {
                        Task { await model.resetCounters() }
                    }
                    if let url = exportedLogURL {
                        ShareLink(item: url) {
                            Label("진단 로그 파일 공유 (IP 마스킹됨)", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("최근 로그") {
                    if model.recentLogs.isEmpty {
                        Text("기록된 로그가 없습니다.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.recentLogs.suffix(40).reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("진단 및 로그")
            .onAppear {
                exportedLogURL = model.exportLogFile()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}
