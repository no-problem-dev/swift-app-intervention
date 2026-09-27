[English](./README.md) | 日本語

# swift-app-intervention

Family Controls を使わずに、選んだアプリを開く前に**立ち止まらせる**（one sec 型）ためのパッケージ。
どの習慣アプリからも使える。ショートカットの自動化が、選んだアプリが開くたびにホストアプリの intent を呼ぶ。
このパッケージは背景で「止めるか」を判定し、止めるときだけホストの立ち止まり画面を前面に出す。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2026+-blue.svg)
![SPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

## しくみ

1. 利用者がショートカットで個人用オートメーションを作る:
   **「Instagram を開いたとき」→「すぐに実行」→「あなたのアプリ: 開く前に立ち止まる」**（「実行時に通知」はオフ）
2. 開くたびに、iOS がホストアプリの intent を**ホストアプリのプロセスで、背景で**実行する
3. コーディネータがパス・最近の開いた記録・ホストの状態を読み、純関数の判定に渡す。ほとんどの実行は画面を出さずに通す
4. 止めるときだけ intent が `continueInForeground` を呼び、立ち止まり画面が出る
5. 利用者が「開く」を選ぶと、パッケージが**パス**を発行して Instagram を開き直す。開き直しで自動化はもう一度動くが、
   パスがあるので通し、新しく開いた回数にも数えない

## 設計

| ターゲット | 役割 | 依存 |
|---|---|---|
| **`AppIntervention`** | モデル・判定・ファイル保存・コーディネータ・受け箱／提示役 | Foundation のみ |
| **`AppInterventionIntents`** | ホスト自前の `AppIntent` から呼ぶ `runIntervention(appID:coordinator:)` | AppIntents |
| **`AppInterventionUI`** | 立ち止まり画面・オートメーション設定ガイド・回数の要約 | SwiftUI, Charts |
| **`AppInterventionFocus`** | ロックとアプリ離脱を見分ける「スマホを置く」セッション | UIKit, CallKit（iOS） |

- **判定の順番:** 戻り窓 → パスより強いロック → 有効なパス → ホストのルール（順に） → 既定。
  ルールは純関数で、最近の開いた記録と、`HostConditionProvider` が 1 回の実行につき 1 度だけ取る `HostSnapshot` を読む
- **失敗したら通す:** 自動化から呼ばれる処理は例外を投げない。保存に失敗しても、前面に出られなくても通す。利用者を閉じ込めない
- **1 回だけ:** `resolve` は 1 つの介入につき 1 回だけ記録する（2 回目は `alreadyResolved`）。
  ホストの台帳の冪等キーには `InterventionContext.id` を使う。パッケージはお金を知らない
- **保存:** バージョン付きの小さな JSON（新しいバージョンのファイルは上書きしない・読めないファイルは退避する）と、追記専用の JSONL の記録
  （知らない種類の行は読み飛ばし、圧縮でも残す）

## 組み込み方

### 1. intent はホストのアプリターゲットに置く

パッケージは `AppIntent`・`AppEnum`・`AppShortcutsProvider`・`IntentModes` の定数を**一切配らない**。測って分かった理由が 2 つある。

- App Intents のメタデータはターゲットごとに抽出され、パッケージからはうまくマージされない
  （ビルドもテストも通るのに、App Shortcuts の発話フレーズだけが何の表示もなく消えた例がある）
- メタデータの抽出は `supportedModes` を**リテラルから**読む。`[.background, .foreground(.dynamic)]` と書くと
  `extract.actionsdata` は `supportedModes: 9` になるが、同じ値でもパッケージの定数を参照すると
  **警告なしで `1`（背景のみ）**になり、アプリが前面に出なくなる

```swift
import AppIntents
import AppIntervention
import AppInterventionIntents

struct PauseBeforeOpeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Before Opening"
    // このファイルにリテラルで書く
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "App") var app: GuardedAppOption   // rawValue == GuardedApp.id

    func perform() async throws -> some IntentResult {
        await runIntervention(appID: app.rawValue, coordinator: Intervention.coordinator)
        return .result()
    }
}
```

ホストのビルド時の確認に `scripts/check-intent-metadata.sh --app <YourApp.app> --intent PauseBeforeOpeningIntent` を入れる。

### 2. 軽いコーディネータ

intent は、iOS がそのためだけに背景で起動したプロセスで実行されることがある。コーディネータはファイルにしか依存しない
static にし、重い SDK の初期化はシーンがつながるまで遅らせる。

```swift
enum Intervention {
    static let apps = [
        GuardedApp(id: "instagram", displayName: "Instagram",
                   reopenURLs: [URL(string: "instagram://")!, URL(string: "https://www.instagram.com")!]),
    ]
    static let coordinator = try! InterventionCoordinator.files(
        at: .applicationSupport,               // ウィジェットも読むときだけ .appGroup("group.…")
        catalog: StaticGuardedAppCatalog(apps),
        policy: {
            InterventionPolicy(rules: [
                LockRule(id: "habits") { $0.host.contains("habits-done") ? nil : LockReason(id: "habits") },
                ScheduleRule(id: "night", window: DailyWindow(start: .init(hour: 22), end: .init(hour: 2)),
                             effect: .intervene("strict")),
            ])
        },
        hostConditions: HostConditions { _, _ in await HabitStore.snapshot() }
    )
}
```

### 3. 立ち止まり画面を出す

```swift
@State private var inbox = InterventionInbox(handoff: Intervention.coordinator.handoff)

WindowGroup {
    RootView()
        // 立ち止まり画面は専用のノードから出す
        .background(Color.clear.fullScreenCover(
            item: Binding(get: { inbox.pending }, set: { if $0 == nil { inbox.dismiss() } })
        ) { context in
            PauseScreen(context: context, presenter: InterventionPresenter(
                coordinator: Intervention.coordinator, inbox: inbox, reopener: SystemAppReopener()))
        })
        .task { await inbox.observe() }
        .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { inbox.refresh() } }
}
```

```swift
InterventionPauseView(context: context) {
    Text("開くと 50 ポイント使います")
} actions: {
    InterventionActionButton(Text("50 払って 15 分使う")) {
        Task {
            let result = try await presenter.proceed(optionID: "pay-50", passDuration: .seconds(900))
            ledger.charge(50, idempotencyKey: result.receipt.contextID)
        }
    }
    InterventionActionButton(Text("やめて 50 貯める"), prominence: .secondary) {
        if let receipt = try? presenter.abandon(optionID: "skip") {
            ledger.reward(50, idempotencyKey: receipt.contextID)
        }
    }
}
```

完全な見本は `Examples/InterventionSample`（XcodeGen・iOS 26）。

### 4. 自動化の設定を案内する

`AutomationSetupGuideView(hostAppName:actionName:)` が手順（トリガーは App、「開いている」「すぐに実行」、
「実行時に通知」をオフ、アクションを追加）を並べ、`shortcuts://` を開く。一番の離脱点なので、上に一番良い図を置く。

### 5. スマホを置くセッション（任意）

```swift
let controller = PhoneDownSessionController(
    store: try FilePhoneDownSessionStore(location: .applicationSupport),
    guardedOpens: CoordinatorGuardedOpenSource(Intervention.coordinator)
)
try controller.start(duration: .seconds(3_600))
// .task { controller.resume(appIsActive: true) }
// .task { await controller.run(events: UIKitPhoneDownEventSource()) }
// for await outcome in controller.outcomes() { reward(idempotencyKey: outcome.sessionID) }
```

セッション中にガード対象のアプリが開かれたら即失敗にする（intent はホストのプロセスで実行されるので確実）。
ロックは保護データの通知で確認する。何も確認できなかった不在は `unconfirmedAbsence` で判定する
（既定は `.fail`。`PhoneDownCapability.current == .lockUndetectable` のときは `.tolerate` を検討する）。

## できないこと

- **止めることはできない。** 利用者は立ち止まりを閉じられるし、自動化を切ることも消すこともでき、アプリからは分からない。
  何日も記録が無いときに `OpenLogQuery.lastRun` を見て確認を出す
- 「実行時に通知」をオフにしない限り、自動化が動くたびに iOS がバナーを出す
- 前面に出る前に、ガード対象のアプリが一瞬見えることがある
- **パスが切れても利用者を追い出せない。** 判定するのは次に開いたときだけ
- 開き直しは他社アプリの URL スキームに頼る（公開されていない）。ユニバーサルリンクを予備に並べ、
  何も開けなければ自分で戻るよう伝える
- スマホを置くセッション: ロックの通知はパスコードが要り、遅れて届くことがある。アプリが停止した後は何も観測できない
- 実機でしか確認できないこと: 自動化から確認なしで前面に出られるか、コールドスタートの遅さ、
  15 秒の戻り窓で開き直しが通るか、保護データの通知のタイミング、「実行時に通知」オフでのバナー

審査メモには設定手順と短い動画を付け、「払う」のはアプリ内ポイントで本物のお金ではないことを明記する。
このパッケージは公開 API しか使わない。

## ドキュメント

API リファレンス: [no-problem-dev.github.io/swift-app-intervention](https://no-problem-dev.github.io/swift-app-intervention/documentation/)。
設計と、それが受けたレビュー: [`docs/DESIGN.md`](docs/DESIGN.md)。

## インストール

```swift
dependencies: [
    .package(url: "https://github.com/no-problem-dev/swift-app-intervention.git", .upToNextMinor(from: "0.1.0"))
]
```

- 合成ルートと intent → `AppIntervention` + `AppInterventionIntents`
- 画面 → `AppInterventionUI`（+ `AppIntervention`）
- スマホを置くセッション → `AppInterventionFocus`

## 動作環境

| Swift | プラットフォーム |
|---|---|
| 6.2 | iOS 26+（コアのビルドとテストのために macOS 26） |

## ライセンス

MIT License. 詳細は [LICENSE](LICENSE) を参照。
