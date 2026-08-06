# HIDTouch

[![CI](https://github.com/koshi545/HIDTouch/actions/workflows/ci.yml/badge.svg)](https://github.com/koshi545/HIDTouch/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#動作要件)

macOS が標準サポートしない USB HID タッチパネルを動かすための、ユーザー空間ドライバーと
キャリブレーション GUI。

[English README](README.md)

macOS には汎用 USB HID デジタイザーのドライバーが存在しません。安価なポータブル
タッチモニターを繋ぐと、ディスプレイとしては映るのにタッチだけが何も起きない、
という状態になります。HIDTouch はパネルの生 HID レポートを読み取り、アフィン変換で
較正してディスプレイ座標へ写像し、カーソル・スクロールイベントとして macOS に届けます。

カーネル拡張も DriverKit も使わず、`IOHIDManager` と `CGEvent` の上でユーザー空間のみで
動作します。

> 商用タッチドライバー製品とは無関係であり、その派生物でもありません。

---

## 現状

**WingCool Inc. TouchScreen (VID `0x27C6` / PID `0x0529`)** を対象に開発しました。
複数のポータブルタッチモニターで使われている Win8 準拠デジタイザーです。
レポート配置はデバイス自身のレポートディスクリプタから実行時に導出しているため、
コードにこのパネル固有の記述はありませんが、動作確認が取れているのはこの1機種のみです。

| 機能 | 状態 |
|---|---|
| 生 HID パケットの観察 | ✅ |
| レポートフォーマット設定 (GUI) | ✅ |
| 4点アフィンキャリブレーション | ✅ |
| マルチディスプレイ対応 | ✅ |
| マルチタッチのパース（最大10点） | ✅ |
| 1本指 → カーソル移動・クリック | ✅ |
| 2本指 → スクロール | ✅ |
| 2本指 → ピンチでズーム | ⚠️ 動作するが非公開 API 依存。既定では無効 |
| 3本指以上 | 追跡・可視化のみ |
| 回転のネイティブジェスチャ送出 | ❌ 未実装 |
| `IOHIDUserDevice` 仮想デジタイザ | ❌ Apple 発行の entitlement が必要 |

---

## 動作要件

- macOS 13 (Ventura) 以降
- Swift 5.9 以降（Xcode Command Line Tools で十分。Xcode 本体は不要）
- USB HID タッチパネル

---

## ビルド

```bash
swift build -c release
```

GUI を署名済み `.app` バンドルとして生成する場合:

```bash
./build_app.sh          # -> dist/HIDTouch Studio.app
```

`build_app.sh` はバンドル生成前に自己テストを実行し、結果として得られた
Designated Requirement を表示します。次のリビルドで権限が維持されるかどうかは
これで判断できます。[権限とコード署名](#権限とコード署名)を参照してください。

---

## 使い方

### 1. 生パケットの観察

```bash
swift run hidtouch-daemon --inspect
```

HID デバイスを列挙し、入力レポートを16進ダンプします。デバイスの排他取得も
イベント注入も行わないため、起動したままにしておいても安全です。

デバイスは**インターフェース単位**で列挙されます。タッチパネルは1つの VID/PID の下に
Mouse (`0x01`/`0x02`)・Digitizer (`0x0D`/`0x02`)・ベンダー定義 (`0xFF00`) の
3インターフェースを公開するのが一般的で、これらを区別できることが解析の前提です。

### 2. HIDTouch Studio でのセットアップ

```bash
open "dist/HIDTouch Studio.app"     # または swift run hidtouch-studio
```

1. **Dashboard** — *Driver Input Device* で対象パネルを指定します。自動判定でも
   動きますが、VID/PID を明示的に固定するほうが確実です。
2. **HID Inspect** — パネルに触れながら Hex ダンプを観察し、X座標・Y座標・
   タッチ状態が何バイト目にあるかを数えます。*Pause* で停止して読めます。
3. **Report Format** — 読み取ったオフセットを入力します。値は即座に反映されるので、
   Dashboard の *Current Raw Point* が指の動きに追従すれば正解です。
4. **Calibrate** — 対象ディスプレイ全面に表示される十字マークを4点タッチします。
   完了後に平均残差が表示されます。数 px 以内であれば良好です。
5. ヘッダーの出力モードを **Mouse Emulation (CGEvent)** に切り替えると
   カーソル制御が有効になります。

> 出力モードの初期値が **Debug / Log Only** なのは意図的です。キャリブレーション前に
> イベント注入を有効にすると、変換行列が単位行列のままカーソルが生センサー座標へ飛び、
> 操作不能になり得ます。

### 3. ドライバーデーモンの常駐実行

Studio が書き出した設定をそのまま使います。

```bash
swift run hidtouch-daemon
```

### 4. コアロジックの自己検証

```bash
swift run core-selftest
```

XCTest / swift-testing は Xcode 本体に同梱されており Command Line Tools には
含まれないため、検証は通常の実行ターゲットとして実装されています。
アフィン変換の復元・退化検出、パーサーの境界条件、設定ファイルの前方互換性、
デバイス分類（実機で観測したデバイス一覧を含む）を検査します。

---

## 権限とコード署名

「システム設定 > プライバシーとセキュリティ」で**入力監視**と**アクセシビリティ**を
許可してください。許可が無い場合、デバイスの列挙はできますが入力レポートが一切届かず、
`IOHIDManagerOpen failed (kr=0xE00002E2)` がログに出ます。

### 許可が消えたように見える理由

これらの権限はパスではなく、バイナリの**コード署名**に紐付けられます。

```console
$ codesign -d -r- "dist/HIDTouch Studio.app"
# designated => cdhash H"8810fec1a40b08cf894ad9da834923178a3dd6b0"
```

ad-hoc 署名（identity `-`）の場合、Designated Requirement は **CDHash** になります。
CDHash はビルド内容が1バイトでも変われば変化するため、リビルドのたびに TCC からは
「別のアプリ」として扱われ、付与済みの許可が無効になります。

さらに厄介なことに、システム設定の一覧にはアプリが有効のまま残るので、
「許可しているのに動かない」状態に見えます。その場合は**一覧から削除して追加し直して**
ください。オン・オフの切り替えでは不十分です。

Studio の Dashboard に現在の許可状態と CDHash が表示されるので、署名が変わったかどうかは
そこで判断できます。

### リビルドしても許可が維持されるようにする

Designated Requirement がハッシュではなく証明書を参照する必要があります。
Developer ID がある場合:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build_app.sh
```

Apple Developer Program に加入していない場合は、**自己署名のコード署名証明書**で
同じ効果が得られます。`HIDTouch Local Signing` という名前で作成しておけば
`build_app.sh` が自動的に検出して使用します。

```console
$ codesign -d -r- "dist/HIDTouch Studio.app"
designated => identifier "com.reo.hidtouch.Studio" and certificate root = H"<証明書のハッシュ>"
```

`certificate root` を参照しているため、CDHash が変わってもこの条件は変化せず、
**リビルドしても権限を付け直す必要がありません**。

証明書の作成手順は以下のとおりです。macOS の Security framework は OpenSSL 3.x が
既定で使う PKCS#12 の MAC アルゴリズムを受け付けないため、`-macalg sha1` と `-legacy` の
指定が必須です。

```bash
# 1. 鍵と自己署名証明書を生成（Code Signing 用途を明示）
openssl req -x509 -newkey rsa:2048 -keyout k.key -out c.crt -days 3650 -nodes \
  -subj "/CN=HIDTouch Local Signing/O=HIDTouch/C=JP" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# 2. macOS が読める PKCS#12 に変換
openssl pkcs12 -export -out c.p12 -inkey k.key -in c.crt \
  -name "HIDTouch Local Signing" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -legacy \
  -passout pass:hidtouch

# 3. ログインキーチェーンへインポート
security import c.p12 -k ~/Library/Keychains/login.keychain-db -P hidtouch \
  -T /usr/bin/codesign -T /usr/bin/security

# 4. 平文の秘密鍵を破棄（鍵はキーチェーン内にある）
rm -f k.key c.p12 c.crt
```

> `security find-identity -v -p codesigning` はこの証明書を「有効なID」として
> 列挙しません（信頼設定を入れていないため）。`codesign` は問題なく使用できるので、
> 信頼設定（管理者パスワードが必要）は不要です。

インポート後の**最初のビルド**は、キーチェーンの認証ダイアログ
（*「codesign が、キーチェーン内のキー "HIDTouch Local Signing" を使用して
署名しようとしています」*）で停止し、応答するまでハングします。
**「許可」ではなく「常に許可」**を押してください。「許可」だと次のビルドでまた止まります。

`security import -T` が設定するのは項目の信頼アプリ一覧で、macOS が実際に参照する
**ACL パーティションリスト**は別物です。これが原因です。

ダイアログを出せない環境（ヘッドレス、CI）向けの非対話的な等価手順:

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -l "HIDTouch Local Signing" ~/Library/Keychains/login.keychain-db
```

キーチェーンパスワードを対話的に聞かれます。`-k <password>` で渡すこともできますが、
シェルの履歴に残ります。

ad-hoc に戻すには、キーチェーンアクセス.app で `HIDTouch Local Signing` を削除するか、
`SIGN_IDENTITY=- ./build_app.sh` を実行します。

なお、Bundle ID も Designated Requirement の一部なので、これを変更した場合も
既存の許可は失効します。

---

## 構成

```text
HIDTouch/
├── Package.swift
├── build_app.sh                     # GUI のバンドル生成と署名
└── Sources/
    ├── CHIDUserDevice/              # IOHIDUserDevice の C API を Swift へ橋渡し
    │   ├── VirtualHIDHelper.c
    │   └── include/VirtualHIDHelper.h
    ├── HIDDriverCore/               # ドライバーのコア共有ライブラリ
    │   ├── HIDDeviceMonitor.swift   # IOHIDManager キャプチャ・デバイス分類
    │   ├── HIDReportDescriptor.swift# レポートディスクリプタ解析・配置導出
    │   ├── HIDParser.swift          # 単一接触レポートのパーサー
    │   ├── MultiTouchParser.swift   # 複数接触レポートのデコード
    │   ├── GestureRecognizer.swift  # 接触数に応じたカーソル / スクロール判定
    │   ├── CalibrationEngine.swift  # 最小二乗法によるアフィン変換行列
    │   ├── JitterFilter.swift       # EMA 平滑化とデッドゾーン
    │   ├── TouchPipeline.swift      # parse → calibrate → filter → inject
    │   ├── CGEventInjector.swift    # CGEvent カーソル・スクロール出力
    │   ├── VirtualHIDDevice.swift   # IOHIDUserDevice 出力（entitlement 必須）
    │   ├── DisplayHelper.swift      # ディスプレイ列挙・座標系変換
    │   ├── Permissions.swift        # TCC 状態と署名情報の取得
    │   ├── Log.swift                # os_log ラッパー
    │   └── ConfigManager.swift      # 設定 JSON の永続化
    ├── TouchDaemon/                 # ヘッドレス CLI ドライバー
    ├── TouchStudio/                 # SwiftUI 設定 GUI
    │   ├── TouchStudioApp.swift     # エントリポイント + AppViewModel
    │   ├── CalibrationWindow.swift  # 対象ディスプレイ全面のキャリブレーション画面
    │   └── ContentView.swift        # ダッシュボード, インスペクタ, 設定, キャンバス
    └── CoreSelfTest/                # コアロジックの検証
```

設定は `~/Library/Application Support/HIDTouch/config.json` に永続化されます。

---

## 技術的な注意点

実際にデバッグ時間を要した、自明でない事柄です。他に十分な情報源が無いため
ここに残しておきます。

### ランループモードは選択肢ではない

HID ソースは **`CFRunLoopMode.commonModes`** に登録する**必要があります**。
`defaultMode` だけに登録すると、次の形で自分自身をデッドロックさせます。

1. タッチが来る → `CGEvent` で mouseDown を送出
2. **自アプリ**のコントロールがそれを受け取り、AppKit が
   `NSEventTrackingRunLoopMode` のトラッキングループへ入る
3. このモードでは `defaultMode` のソースが処理されないため、HID レポートが止まる
4. 指を離したレポートを読めず、mouseUp を送出できない
5. AppKit は永遠に来ない mouseUp を待ち続ける

症状は妙に限定的で、**自アプリの UI だけがタッチに反応しなくなり**、
他アプリと実マウスは正常なままです。他アプリは自前のランループを持ち、
実マウスのイベントはこのプロセスを経由せずウィンドウサーバー経由で届くためです。

同じ理由から、リリースを遅延させるタイマーも
`RunLoop.main.add(timer, forMode: .common)` で登録します。
`DispatchQueue.main.asyncAfter` ではトラッキング中の発火が保証されません。

### 合成クリックの要件

`CGEvent` から AppKit が受け入れるクリックを作るには、3つの条件が必要です。

- **`kCGMouseEventClickState` に 1 を設定する** — 未設定だと `NSEvent.clickCount` が
  0 になり、コントロールは単に無視します
- **mouseDown と mouseUp を同一イベントサイクルに入れない** — 潰れると mouseUp が失われ、
  ボタンが押しっぱなしのまま残ります。`minimumPressDuration` が最短 40ms を保証します
- **両者を同じ座標で送る** — 離れているとドラッグとして解釈されます

またパネルは接触中に一瞬だけ空フレームを出すことが珍しくないため、
リリースは `liftDebounce`（既定 30ms）待ってから確定します。
これが無いとクリックが切れたりドラッグが分断されたりします。

### スクロールとジェスチャーのイベントは座標を持たない

マウスイベントは座標を持ちますが、スクロールホイールイベントとジェスチャーイベントは
持ちません。ウィンドウサーバーはどちらも**カーソル**の下にあるものへ配送します。
2本指のパンはカーソルを動かさないので、マルチディスプレイ環境ではポインタが最後に
置かれていた画面へスクロールが飛びます。触っている画面とは限りません。

そのため接触点の中点を明示的に渡し、カーソルのワープと `event.location` の両方を
設定しています。配送自体はイベントの座標で決まりますが、`NSEvent.mouseLocation` を
読むアプリやホバー表示は実カーソルを見るため、ポインタを別画面に残したままだと
配送先が正しくても見た目が破綻します。

目に見える帰結として、**スクロールやピンチをするとカーソルがパネル側へ移動します**。
タッチスクリーンとしては正しい挙動ですが、副作用ではなく意図した動作です。

### Win8 デジタイザーを起こす

Win8 準拠のパネルは、ホストが Device Configuration フィーチャレポート
（Digitizer usage `0x0E` 内の Device Mode `0x52`）に `0x02` を書き込むまで、
単一接触のマウスエミュレーションモードで動作します。macOS はこれを送らないため、
デジタイザーインターフェースが無音に見えます。

列挙時に一度書くだけでは不十分で、しかも**読み返しは信用できません**。開発対象の
パネルは書き込みを受理し、読み返すと Device Mode `0x02` を返し、その1〜2秒後に
自身の初期化を終える過程で `0x00` へ戻ります。つまりレジスタはマルチタッチだと
主張しながら、ハードウェアはマウスエミュレーションのパケットを出し続けます。
`02` を読んで `02` を書いて成功と判定するドライバーは、ログに何も残さないまま
マルチタッチを死なせます。また、レジスタが既に保持している値の書き込みは
ファームウェア内部で no-op になり得るため、目標モードへは必ず明示的な `0x00` を
経由して遷移させます。

信用できる証拠は「デジタイザが実際に喋ったか」だけなので、判定はそこに置いています。

- デジタイザがレポートを出すまでタイマーで再武装する（2.5秒間隔・最大5回）。
  これで復帰タイミングを1つに決め打ちせずに反転の窓を覆えます
- デジタイザが一度も喋っていないのにパネルの**マウス**コレクションからタッチが
  届いたら、それはマウスエミュレーションモードにいる証拠なので即座に再武装する
  （こちらは独立した試行回数を持ちます）

後者はスリープ復帰や USB 再列挙でパネルが電源断された場合の復旧も兼ねます。
ハードウェアの実際の挙動に追従するので、電源通知の監視も「どのイベントが
パネルをリセットするか」の推測も不要です。

バッファ形式は `[reportID, mode, id]` と `[mode, id]` の両方を試します。
どちらを期待するかはパネルによって一貫していません。

接触ブロックの構造はパネルごとに異なる（圧力・幅・高さを含む機種がある）ので、
`HIDReportDescriptor` がレポートディスクリプタを解析して接触数・各フィールドの
ビット位置・論理範囲を自動導出します。導出結果は Dashboard の
*Multi-Touch* セクションに表示されます。

### 出力側の制約

**macOS にはマルチタッチを注入する公開 API が存在しません。**

`IOHIDUserDeviceCreate` は制限付き entitlement
`com.apple.developer.hid.virtual.device` を必要とします。これは Apple が
開発チーム単位で付与し、プロビジョニングプロファイルへの埋め込みが前提となるため、
ad-hoc 署名や自己署名のビルドでは取得できません。仮想デバイスを作成できない場合、
自動的にマウスエミュレーションへフォールバックし、Dashboard に警告を表示します。

### ピンチ — 本プロジェクト唯一の非公開 API

これ以外はすべて公開 API です。ピンチだけが例外で、それゆえ Settings のスイッチで
**既定では無効**にしてあります。

macOS はピンチをアプリへ `NSEvent` の `.magnify` として届けますが、これを生成する
公開 API は存在しません。`CGEvent` が扱えるのはマウス・キーボード・スクロールホイールまでです。
ウィンドウサーバーが実際に読む符号化は次のとおりです。

```swift
let event = CGEvent(source: source)
event.type = CGEventType(rawValue: 29)!                              // NSEventTypeGesture
event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)   // kIOHIDEventTypeZoom
event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
event.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
event.post(tap: .cghidEventTap)
```

イベントタイプとこの3つのフィールド番号は、どの SDK ヘッダにも存在しません。
位相の値は公開（`CGEventTypes.h` の `CGGesturePhase`）で、HID タイプは
`kIOHIDEventTypeZoom` と一致します。それ以外について Apple は何も保証しておらず、
**壊れ方は静かです** — 認識されないジェスチャーイベントは単に破棄されるため、
将来の macOS がピンチを無効化してもエラーはどこにも出ません。
その際に見るべき場所は `CGEventInjector.Gesture` です。

ジェスチャーは必ず閉じる必要があります。`began` を送って `ended` を送らないと、
受け取ったアプリはジェスチャーハンドラの中に留まり続けます。指を離してもズームが
追従し、次のピンチが前回の続きとして扱われます。呼び出し側が忘れられないよう、
位相の状態は注入側が保持し、magnify 以外の結果が出た時点で自動的に閉じます。

回転も原理的には同じ方法で送れますが、実装していません。

#### ピンチとパンの判別

2本指はどちらの意味にもなり得ますし、実際には両方が同時に起きています。ピンチでは
必ず重心が多少ずれ、パンでは必ず指の間隔が揺れます。判定には**ジェスチャー開始時点
からの正味変化**を使い、フレームごとの変化量の累積は使いません。累積すると絶対値の
ノイズが単調に積み上がり、長くゆっくりしたパンがいずれ揺らぎだけでピンチのしきい値を
越えてしまうためです。先にしきい値を越えたほうが採用され、**指を離すまで判定は
固定**されます。ピンチ中に重心がずれてスクロールへ化けるのを防ぐためです。

### イベントのトレース

送出したイベントと実際に配送されたイベントを突き合わせられます。
クリックのたびにログが出ること、受信側は他アプリのイベントも観測することから、
既定では無効です。

```bash
HIDTOUCH_EVENT_TRACE=1 "dist/HIDTouch Studio.app/Contents/MacOS/TouchStudio"

# 別ターミナルで（zsh の log ビルトインと衝突するのでフルパス必須）
/usr/bin/log show --last 2m --info \
  --predicate 'subsystem == "com.reo.hidtouch"' --style compact | grep EVT
```

`posted DOWN` に対して `posted UP` と `local UP` が対で並んでいれば正常です。
`posted` はあるのに `local` が無ければ配送で失われており、
`local` があるのに反応しなければ受け取った側の解釈の問題です。

### デバイスの排他取得 (Seize)

タッチパネルと判定されたデバイスは `kIOHIDOptionsTypeSeizeDevice` で
排他オープンし、macOS 標準ドライバが同じレポートからカーソルを動かすのを防ぎます。
キーボードやマウスが対象になることはありません。Report Format タブで無効化できます。

なお、デバイスは `IOHIDManagerOpen` ではなく**個別に**オープンしています。
マネージャ単位のオープンは all-or-nothing で、1台でも他プロセス
（例: Karabiner-Elements）が排他保持していると `kIOReturnExclusiveAccess` で
全体が失敗します。加えて非排他の claim を保持するため、デバイス単位の
seize も効かなくなります。

---

## トラブルシューティング

| 症状 | 原因 |
|---|---|
| デバイスは列挙されるがレポートが届かない | 入力監視が未許可、または古い署名に対して許可されている |
| 許可済みに見えるのに動かない | リビルドで CDHash が変化した。一覧から削除して追加し直す |
| カーソルが隅や画面外へ飛ぶ | 未キャリブレーション。変換行列が単位行列のまま |
| 別のディスプレイでカーソルが動く | Dashboard の対象ディスプレイ指定が違う |
| デジタイザーインターフェースが無音 | Win8 device mode が受理されていない。Multi-Touch セクションを確認 |
| 自アプリの UI だけタッチに反応しない | HID ソースが `commonModes` に無い（上記参照） |

---

## ライセンス

MIT。[LICENSE](LICENSE) を参照してください。
