import SwiftUI

/// 「能说什么」说明页，对应 Android 版的 `showHelp()` 文案。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, [String])] = [
        ("状态提醒", [
            "登录后开启监控，前台每 60 秒同步一次车况，",
            "以下变化会推送通知并在主界面列卡片：",
            "· 门锁（闭锁/解锁）",
            "· 车窗/天窗（开/关）",
            "· 后备箱（开/关）",
            "· 发动机（启动/熄火）",
            "· 空调（开/关）",
            "· 电量跌破 30%/20%/10%",
            "· 续航不足 100/50 km",
        ]),
        ("远程启动", [
            "启动前会检查车门是否关好、电量是否充足；",
            "可选用 10/15/20/30 分钟运行时长，到点或熄火后自动停机。",
        ]),
        ("空调控制", [
            "车辆启动后才能开空调、除霜、方向盘加热，",
            "熄火状态下这些按钮会变暗并有说明。关空调不受此限制。",
            "结果同样以车况里空调字段是否变化为准。",
        ]),
        ("手动远控", [
            "下方按钮是手动远控，执行结果也会出现在提醒流里。",
            "判断依据是车况里对应字段是否变化，而不是接口回执。",
        ]),
        ("iOS 限制", [
            "iOS 不允许应用长期驻留后台，因此后台刷新由系统调度，",
            "可能比 Android 版稀疏。前台使用时仍为 60 秒一次。",
            "Android 的「开机自启」在 iOS 上不存在此能力。",
        ]),
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Palette.bgRoot.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sections, id: \.0) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.0)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Palette.pink)
                                ForEach(section.1, id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 12.5))
                                        .foregroundColor(Palette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .doroCard()
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Doro 车控说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Palette.pink)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// 多车辆切换
struct VehiclePickerView: View {
    @EnvironmentObject private var repo: GwmRepository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Palette.bgRoot.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(repo.vehicles) { v in
                            Button {
                                repo.selectVehicle(v)
                                dismiss()
                                Task { await repo.refreshNow() }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(v.displayName)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(Palette.textPrimary)
                                        Text(v.subtitle(effectivePlatform: nil))
                                            .font(.system(size: 11))
                                            .foregroundColor(Palette.textHint)
                                    }
                                    Spacer()
                                    if repo.selectedVin == v.vin {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Palette.stateOk)
                                    }
                                }
                                .doroCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("选择车辆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundColor(Palette.pink)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
