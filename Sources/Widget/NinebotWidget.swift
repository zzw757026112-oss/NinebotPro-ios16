// NinebotWidget — App Groups 测试小组件（1.3.27）。
// 只做一件事：读 App Group 共享存储里的 NEWidgetTest，显示出来。
// 显示时间 = App Groups 跟自签名安装合得来，可以继续做完整版小组件。
// 显示 NO DATA = 共享存储读不到，这条路不通。
import WidgetKit
import SwiftUI

private let kAppGroupID = "group.com.corpsezhao.ninebotcast"
private let kTestKey = "NEWidgetTest"

private func readTestValue() -> String {
    guard let shared = UserDefaults(suiteName: kAppGroupID) else { return "NO DATA" }
    return shared.string(forKey: kTestKey) ?? "NO DATA"
}

struct WidgetTestEntry: TimelineEntry {
    let date: Date
    let testValue: String
}

struct WidgetTestProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetTestEntry {
        WidgetTestEntry(date: Date(), testValue: "…")
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetTestEntry) -> Void) {
        completion(WidgetTestEntry(date: Date(), testValue: readTestValue()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetTestEntry>) -> Void) {
        let entry = WidgetTestEntry(date: Date(), testValue: readTestValue())
        // 15 分钟后刷新一次；App 每次打开都会重写值并主动刷新小组件。
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }
}

struct WidgetTestEntryView: View {
    var entry: WidgetTestEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App Groups 测试")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Text(entry.testValue)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(entry.testValue == "NO DATA" ? .red : .green)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
            Text(entry.date, style: .time)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
    }
}

struct NinebotWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NinebotWidget", provider: WidgetTestProvider()) { entry in
            WidgetTestEntryView(entry: entry)
        }
        .configurationDisplayName("Ninebot Pro+ 测试")
        .description("App Groups 共享存储测试")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NinebotWidgetBundle: WidgetBundle {
    var body: some Widget {
        NinebotWidget()
    }
}
