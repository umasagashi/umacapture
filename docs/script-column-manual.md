# スクリプト列 ユーザーマニュアル

スクリプト列は、**行の絞り込み条件**と**セルの表示内容**を Dart スクリプトで自由に定義できる列です。
レーティング列やスキル列のような固定の列ではできない、独自の条件・独自の表示を作れます。

> このマニュアルは、キャプチャや他の列の使い方は分かっているが、スクリプト列は初めて、という方向けです。
> プログラミングが初めてでも、ここに書かれた範囲だけで全機能を使えるように書いています。

---

## 目次

1. [スクリプト列とは](#1-スクリプト列とは)
2. [列を追加する](#2-列を追加する)
3. [2つの関数：`filter` と `display`](#3-2つの関数filter-と-display)
4. [最小の例](#4-最小の例)
5. [`record` から読めるデータ（全リファレンス）](#5-record-から読めるデータ全リファレンス)
6. [コレクションの操作](#6-コレクションの操作)
7. [`null`（値が無い）かもしれない項目の扱い](#7-null値が無いかもしれない項目の扱い)
8. [`filter` 関数の書き方](#8-filter-関数の書き方)
9. [`display` 関数の戻り値](#9-display-関数の戻り値)
10. [`Cell`：表示を細かく制御する](#10-cell表示を細かく制御する)
11. [色の指定方法](#11-色の指定方法)
12. [アイコンの指定方法](#12-アイコンの指定方法)
13. [カラーマップ関数（数値→色）](#13-カラーマップ関数数値色)
14. [並べ替え（ソート）の仕組み](#14-並べ替えソートの仕組み)
15. [チェックと保存・エラー表示](#15-チェックと保存エラー表示)
16. [使える書き方・避ける書き方](#16-使える書き方避ける書き方)
17. [レシピ集（そのまま使える例）](#17-レシピ集そのまま使える例)
18. [クイックリファレンス](#18-クイックリファレンス)

---

## 1. スクリプト列とは

1 レコード（1 頭のウマ娘の記録）ごとに、あなたの書いた 2 つの関数が実行されます。

- **`filter`** … その行をテーブルに表示するか（`true` で表示、`false` で非表示）
- **`display`** … そのセルに何を表示するか（文字列・数値・色付きセルなど）

両方とも 1 つのコード欄に書きます。共通で使いたい計算は**ヘルパ関数**として同じ欄に書けます。

---

## 2. 列を追加する

1. 列の追加メニューから **「スクリプト」** を選びます。
2. **タイトル**（列見出し）を入力します。
3. **コード欄**に `filter` と `display` の 2 関数を書きます（次章）。
4. **「チェック」**ボタンで確認します（先頭の数件に対して実行し、テーブルでの見え方と平均実行時間を表示）。
5. **チェックが通ると保存（OK）ボタンが押せるようになります。** コンパイルエラー・実行エラー・処理が重すぎる場合は保存できません（[15 章](#15-チェックと保存エラー表示)）。

---

## 3. 2つの関数：`filter` と `display`

コード欄には、必ず次の 2 つの関数を書きます。**関数名（`filter`/`display`）と引数の型（`CharaRecord`）は固定**です（引数名は自由）。

```dart
// 行を表示するなら true、隠すなら false を返す
bool filter(CharaRecord r) {
  return r.status.speed >= 1000;
}

// セルに表示する内容を返す（文字列・数値・Cell など）
dynamic display(CharaRecord r) {
  return r.status.speed;
}
```

- **絞り込みをしたくない**場合も `filter` は必要です。下のように `true` を返せば全行が表示されます。

  ```dart
  bool filter(CharaRecord r) {
    return true;
  }
  ```

- このマニュアルでは読みやすさのため、関数の中身を `{ return ...; }` の形で統一して書きます。
  これは表記を揃えるためのもので、あなたが `bool filter(CharaRecord r) => r.status.speed >= 1000;` のような
  アロー記法（`=>`）で書いても構いません。お好みでどうぞ。

### 共有ヘルパ

同じ計算を `filter` と `display` の両方で使いたいときは、**ヘルパ関数**を同じ欄に書いて両方から呼べます。

```dart
// 本人＋親のスピード因子の星合計（filter と display の両方から使う）
num speedStars(CharaRecord r) {
  return r.factorGroups.where((g) => g.name == "スピード").map((g) => g.totalStar).sum;
}

bool filter(CharaRecord r) {
  return speedStars(r) >= 4;
}

dynamic display(CharaRecord r) {
  return "スピード因子 ${speedStars(r).toInt()}★";
}
```

---

## 4. 最小の例

「スピードが 1000 以上の行だけを表示し、スピード値をセルに出す」だけなら：

```dart
bool filter(CharaRecord r) {
  return r.status.speed >= 1000;
}

dynamic display(CharaRecord r) {
  return r.status.speed;
}
```

---

## 5. `record` から読めるデータ（全リファレンス）

`filter`/`display` の引数（上の例の `r`）が 1 レコードです。読めるものは以下がすべてです。

> **「ID」について**
> スキル・因子・シナリオ・サポートカードなどの `id` は、**ゲーム内の ID ではなく umacapture が定める内部 ID** です。
> 0 から始まる連番ですが、**番号の順序に意味はありません**（小さい/大きいで何かを表すわけではない）。
> 新しいスキルや因子には新しい ID が割り当てられ、**既存の ID は今後のバージョンでも変わらないことが保証**されます。
> そのため、名前の表記揺れに左右されない「厳密な一致」に `id` を使えます（[5.10](#510-コード化された項目coded--namecode)の `$Coded.code` も同様に内部コードです）。

### 5.1 レコード直下

| 書き方 | 型 | 説明 |
|---|---|---|
| `r.status` | Status | 5 つのステータス |
| `r.aptitudes` | Aptitudes | 適性（バ場・距離・脚質） |
| `r.skills` | スキルの一覧 | 所持スキル |
| `r.factors` | 因子の一覧 | 本人・親の因子（1 件ずつフラットに並ぶ） |
| `r.factorGroups` | 因子グループの一覧 | 同じ因子を本人＋親で合算した一覧（表示向き） |
| `r.races` | レースの一覧 | 出走したレース |
| `r.supportCards` | サポカの一覧 | 編成サポートカード |
| `r.scenario` | Scenario | シナリオ |
| `r.trainee` | $Coded | ウマ娘（`.name` がキャラ名、[5.10](#510-コード化された項目coded--namecode)） |
| `r.charaRank` | $Coded | キャラランク（`.name` が `"SS"` など。評価値から算出） |
| `r.family` | Family | 継承の親・祖父母（[5.11](#511-継承の親family)） |
| `r.ratings` | Ratings | レーティング（[5.8](#58-サポカシナリオレーティングメモ)） |
| `r.memos` | Memos | メモ（[5.8](#58-サポカシナリオレーティングメモ)） |
| `r.metadata` | Metadata | 記録の付帯情報 |
| `r.evaluationValue` | int | 評価値 |
| `r.fans` | int | ファン数 |
| `r.trainedDate` | String | 育成日（文字列） |
| `r.capturedDate` | String | 取得日時（文字列） |
| `r.id` | String | レコードの内部 ID（通常は使いません） |

### 5.2 Status（ステータス）

すべて `int`。

```dart
r.status.speed        // スピード
r.status.stamina      // スタミナ
r.status.power        // パワー
r.status.guts         // 根性
r.status.intelligence // 賢さ
```

### 5.3 Aptitudes（適性）

バ場 `ground`・距離 `distance`・脚質 `style` の各方向にアクセスできます。各方向の値は
**ランク**（`$Coded`、[5.10](#510-コード化された項目coded--namecode) 参照）で、`.name` がランク文字（`"A"`〜`"G"`）、
`.code` がランクの大きさ（**`A`=7 … `G`=1**、大きいほど高い）。

```dart
r.aptitudes.ground.turf          // 芝適性（ランク）
r.aptitudes.ground.dirt          // ダート適性
r.aptitudes.distance.short       // 短距離
r.aptitudes.distance.mile        // マイル
r.aptitudes.distance.middle      // 中距離
r.aptitudes.distance.long        // 長距離
r.aptitudes.style.leadPace       // 逃げ
r.aptitudes.style.withPace       // 先行
r.aptitudes.style.offPace        // 差し
r.aptitudes.style.lateCharge     // 追込

// 使い方
r.aptitudes.distance.long.name == "A"   // ちょうど A か
r.aptitudes.distance.long.code >= 5     // C 以上か（A=7,B=6,C=5,…）
```

### 5.4 スキル（`r.skills` の各要素）

| 書き方 | 型 | 説明 |
|---|---|---|
| `s.id` | int | スキル ID（内部 ID。冒頭の注を参照） |
| `s.name` | String | スキル名（例 `"スピードスター"`） |
| `s.level` | int? | レベル（無い場合 `null`） |
| `s.hasTag("nige")` | bool | タグを持つか |

### 5.5 因子（`r.factors` の各要素）

`r.factors` は本人・親 1・親 2 の因子が**1 件ずつ**並んだ一覧です。

| 書き方 | 型 | 説明 |
|---|---|---|
| `f.id` | int | 因子 ID（内部 ID） |
| `f.name` | String | 因子名（例 `"スピード"`） |
| `f.star` | int | 星数（1〜3） |
| `f.subject` | $Coded | 誰の因子か（`.name` が `"本人"`/`"親1"`/`"親2"`、`.code` が `0`/`1`/`2`） |
| `f.hasTag("status")` | bool | タグを持つか |

### 5.6 因子グループ（`r.factorGroups` の各要素）

同じ因子を本人＋親で合算した一覧です。「スピード因子が合計いくつ」を見たいときに便利。

| 書き方 | 型 | 説明 |
|---|---|---|
| `g.id` | int | 因子 ID（内部 ID） |
| `g.name` | String | 因子名 |
| `g.totalStar` | int | 星合計（本人＋親 1＋親 2） |
| `g.selfStar` | int | 本人の星 |
| `g.parent1Star` | int | 親 1 の星 |
| `g.parent2Star` | int | 親 2 の星 |
| `g.hasTag("status")` | bool | タグを持つか |

### 5.7 レース（`r.races` の各要素）

| 書き方 | 型 | 説明 |
|---|---|---|
| `e.title` | $Coded | レース名（`.name`） |
| `e.place` | int | 着順 |
| `e.position` | int | 通過順位など |
| `e.won` | bool | 勝ったか |
| `e.ground` | $Coded | バ場（`.name` が `"芝"`/`"ダート"`） |
| `e.distance` | $Coded | 距離区分（`.name` が `"短距離"`/`"マイル"`/`"中距離"`/`"長距離"`） |
| `e.strategy` | $Coded | 脚質（`.name` が `"逃げ"`/`"先行"`/`"差し"`/`"追込"`） |
| `e.weather` | $Coded | 天候（`.name` が `"晴"`/`"曇"`/`"雨"`/`"雪"`） |

### 5.8 サポカ・シナリオ・レーティング・メモ

```dart
// r.supportCards の各要素
c.id      // int（内部 ID）
c.rank    // $Coded（.name が "SSR" など、.code がランクの大きさ）
c.level   // int

// r.scenario
r.scenario.id     // int（内部 ID）
r.scenario.name   // String（例 "アオハル杯"）
```

レーティングとメモは、どちらも**キー**で参照します。キーは、レーティング設定・メモ列で作った
各枠のキー（対応する標準のレーティング列／メモ列で使っているものと同じ）です。値が無ければ `null`。

```dart
r.ratings.get("main")          // double?（そのキーが無ければ null）
r.ratings.get("main") ?? 0.0   // 無いとき 0.0 として扱う（推奨）

r.memos.get("main")            // String?（そのキーが無ければ null）
(r.memos.get("main") ?? "")    // 無いとき空文字として扱う（推奨）
```

### 5.9 Metadata（付帯情報）

```dart
r.metadata.recordType   // $Coded（.name が "標準" など）
r.metadata.strategy     // $Coded（脚質）
r.metadata.isFriend     // bool（フレンド記録か）
```

### 5.10 コード化された項目（`$Coded` = `.name`/`.code`）

バ場・距離・脚質・天候・適性ランク・因子の subject・サポカ rank など、**選択肢が決まっている項目**は
共通して `$Coded` 型です。次の 2 つを持ちます。

- `.name` … 表示用ラベル（**標準列に出ているのと同じ表記**。例：`"芝"`、`"逃げ"`、`"A"`、`"本人"`）
- `.code` … 内部の数値コード。**順序のあるもの（適性ランク等）は `.code` で大小比較**できます。

```dart
e.ground.name == "芝"                 // バ場が芝
r.aptitudes.distance.long.code >= 5   // 長距離適性が C 以上
```

> ラベルの正確な表記は、対応する標準列の表示に合わせてください（上の例は代表値です）。

### 5.11 継承の親（`family`）

`r.family` は継承元（親 2 体）と、その親（祖父母）のツリーです。各人物は `$Coded`
（[5.10](#510-コード化された項目coded--namecode)）で、`.name` がウマ娘名・`.code` が内部コードです。

| 書き方 | 型 | 説明 |
|---|---|---|
| `r.family.parent1` | Parent | 親 1（とその親 2 体） |
| `r.family.parent2` | Parent | 親 2（とその親 2 体） |
| `r.family.parent1.self` | $Coded | 親 1 本人（ウマ娘名） |
| `r.family.parent1.parent1` | $Coded | 親 1 の親（祖父母）|
| `r.family.parent1.parent2` | $Coded | 親 1 のもう一方の親 |
| `r.family.parent1.rental` | bool? | 親 1 がレンタル（フレンド）か（不明なら `null`） |

`parent2` も同じ構造です。

```dart
// 親のどちらかが特定のウマ娘か
r.family.parent1.self.name == "サイレンススズカ" ||
    r.family.parent2.self.name == "サイレンススズカ"

// レンタル親を使っているか（null は false 扱い）
(r.family.parent1.rental ?? false) || (r.family.parent2.rental ?? false)
```

---

## 6. コレクションの操作

`r.skills` / `r.factors` / `r.factorGroups` / `r.races` / `r.supportCards` は**一覧（コレクション）**です。
添字（`[0]` のような書き方）は使えません。代わりに次のメソッドで扱います。

### 6.1 絞り込み・判定

| 書き方 | 戻り | 説明 |
|---|---|---|
| `.where((e) => 条件)` | 一覧 | 条件に合う要素だけの一覧 |
| `.whereNot((e) => 条件)` | 一覧 | 条件に**合わない**要素だけの一覧 |
| `.any((e) => 条件)` | bool | 1 つでも条件に合えば `true` |
| `.every((e) => 条件)` | bool | すべて条件に合えば `true` |
| `.length` | int | 件数 |
| `.isEmpty` / `.isNotEmpty` | bool | 空か／空でないか |
| `.first` | 要素 | 先頭。**空のときはエラー**になります |
| `.firstOrNull` | 要素? | 先頭。空のときは `null`（安全） |

`(e) => 条件` は「各要素 `e` について `条件` を判定する式」で、**クロージャ**と呼びます（`=>` を使うのはここだけ）。
`e` には [5 章](#5-record-から読めるデータ全リファレンス) の各要素（スキルなら `s.name` など）が入ります。
条件は `&&`（かつ）・`||`（または）・`!`（否定）で組み合わせられます。

```dart
// スピード因子（本人以外）を 2★以上持っているか
r.factors.where((f) => f.name == "スピード" && f.star >= 2 && f.subject.name != "本人").isNotEmpty
```

### 6.2 取り出し・集計（`map` と数値の集計）

`.map((e) => 値)` は各要素から値を取り出した**値の一覧**を作ります。値の一覧には次が使えます。

| 書き方 | 戻り | 説明 |
|---|---|---|
| `.sum` | num | 合計（空のとき 0） |
| `.max` / `.min` | num? | 最大／最小（空のとき `null`） |
| `.average` | num? | 平均（空のとき `null`） |
| `.length` | int | 件数 |
| `.join(", ")` | String | 文字列として連結（区切りは省略すると `", "`） |

```dart
r.factorGroups.map((g) => g.totalStar).sum            // 全因子の星合計
r.factorGroups.map((g) => g.totalStar).max ?? 0       // 一番多い因子の星
r.skills.map((s) => s.name).join(", ")                // スキル名を「, 」でつなぐ
```

> `null` になり得る項目（例: `s.level`）を `.map` で取り出して集計するとエラーになります。
> [7.1 節](#71-null-を含む一覧の集計に注意)を参照してください。

### 6.3 つなげて書く（チェーン）

メソッドはつなげられます。

```dart
// 逃げタグの付くスキルの数
r.skills.where((s) => s.hasTag("nige")).length

// スピード因子グループの星合計（本人＋親）
r.factorGroups.where((g) => g.name == "スピード").map((g) => g.totalStar).sum
```

---

## 7. `null`（値が無い）かもしれない項目の扱い

`s.level`（スキルレベル）や `r.ratings.get(...)`、`.firstOrNull` は **`null`（値が無い）になり得ます**。
そのまま比較するとエラーになるので、次のどれかで安全に扱ってください。

```dart
// 1) まず null かどうか確かめてから使う
r.skills.where((s) => s.level != null && s.level! > 1)

// 2) null のときの既定値を ?? で与える（おすすめ）
r.skills.where((s) => (s.level ?? 0) > 1)
(r.ratings.get("main") ?? 0.0) >= 4.0

// 3) null かもしれない要素は ?. と ?? を組み合わせる
(r.factorGroups.where((g) => g.name == "スピード").firstOrNull?.totalStar ?? 0) >= 4
```

- `x ?? 既定値` … `x` が `null` なら「既定値」を使う。
- `x?.プロパティ` … `x` が `null` なら全体が `null`（エラーにしない）。
- `x!` … 「`x` は `null` でない」と断言（`!= null` で確かめた後にだけ使う）。

### 7.1 `null` を含む一覧の集計に注意

`s.level` のような **`null` になり得る項目**を `.map(...)` で取り出してから `.sum` / `.average` /
`.max` / `.min` で集計すると、`null` が混ざった時点でエラーになります（その行は ⚠ 表示になります）。
集計の前に `null` を取り除くか、既定値に置き換えてください。

```dart
// 誤: level が null のスキルがあるとエラーになる
r.skills.map((s) => s.level).average

// 正: 先に null を除外してから集計する
r.skills.where((s) => s.level != null).map((s) => s.level!).average

// 正: map の中で既定値（ここでは 0）に置き換える
r.skills.map((s) => s.level ?? 0).average
```

---

## 8. `filter` 関数の書き方

`bool` を返します。`true` の行が表示され、`false` の行は隠れます。

```dart
// 単純なしきい値
bool filter(CharaRecord r) {
  return r.status.speed >= 1100;
}

// 複数条件（かつ／または）
bool filter(CharaRecord r) {
  return r.status.speed >= 1000 &&
      (r.status.stamina >= 600 || r.status.power >= 900);
}

// スキル名で
bool filter(CharaRecord r) {
  return r.skills.any((s) => s.name.contains("スピード"));
}

// 絞り込みをしない（全行表示）
bool filter(CharaRecord r) {
  return true;
}
```

---

## 9. `display` 関数の戻り値

`display` は**何を返してもよく**、セルの表示はアプリ側が次のように決めます。

| 返したもの | セルの表示 | 並べ替えのキー |
|---|---|---|
| `String`（文字列） | そのまま | 文字列の辞書順 |
| `num`（数値）/ `bool` | 文字列化して表示 | 数値（数値順に並ぶ） |
| 一覧（`map` の結果など） | 各要素を `", "` でつないで表示 | なし（辞書順） |
| `Cell(...)`（[10 章](#10-cell表示を細かく制御する)） | `Cell` の指定どおり | `Cell` の `sort` |
| `null` | 空欄 | なし |
| `$Coded` などのオブジェクトをそのまま | **エラー（⚠）** | — |

> **注意：** コード化項目（`$Coded`、[5.10](#510-コード化された項目coded--namecode)）やレコードの一部を
> **そのまま返すとエラー**になります（以前は空欄になっていました）。`.name` / `.code` で値を取り出すか、
> `Cell(...)` を使ってください。例：`return r.scenario;` ではなく `return r.scenario.name;`。

```dart
dynamic display(CharaRecord r) {
  return r.status.speed;                          // 数値（数値順ソート）
}

dynamic display(CharaRecord r) {
  return "${r.status.speed}/${r.status.stamina}"; // 文字列
}

dynamic display(CharaRecord r) {
  return r.skills.map((s) => s.name);             // 一覧 → 「, 」連結
}
```

---

## 10. `Cell`：表示を細かく制御する

「表示は文字、並びは数値」「色を付ける」などをしたいときは `Cell` を返します。

```dart
Cell(表示文字列, {sort: 並べ替えキー, color: 文字色, background: 背景色, icon: アイコン名, iconColor: アイコン色})
```

すべて省略可能です（`Cell("文字だけ")` も可）。

| 引数 | 型 | 説明 |
|---|---|---|
| 第 1 引数 | String | セルに表示する文字列 |
| `sort` | 数値 or 文字列 | 並べ替えに使う値（[14 章](#14-並べ替えソートの仕組み)） |
| `color` | String | 文字色（[11 章](#11-色の指定方法)） |
| `background` | String | 背景色 |
| `icon` | String | 先頭に出すアイコン名（[12 章](#12-アイコンの指定方法)） |
| `iconColor` | String | アイコンの色 |

```dart
// 表示は文字・並びは星合計（数値）
dynamic display(CharaRecord r) {
  final n = r.factorGroups.where((g) => g.name == "スピード").map((g) => g.totalStar).sum.toInt();
  return Cell("スピード ${n}★", sort: n);
}

// 条件で色を変える＋アイコン
dynamic display(CharaRecord r) {
  final s = r.status.speed;
  final high = s >= 1200;                 // 条件は先に変数へ（理由は 16 章）
  return Cell("$s",
      sort: s,
      color: when(high, "white"),         // high なら "white"、そうでなければ既定
      background: when(high, "green"),
      icon: when(high, "star"),
      iconColor: "amber");
}
```

> **`when(条件, 値)`** は「`条件` が成り立てば `値`、そうでなければ既定（`null`）」を表す関数です。
> 色・アイコン・`sort` を**条件で出し分けたいときは必ず `when(...)` を使ってください**。
> `条件 ? 値 : null` という書き方は内部の制約でうまく動かないことがあります（[16 章](#16-使える書き方避ける書き方)）。

---

## 11. 色の指定方法

`color` / `background` / `iconColor` には**色名の文字列**または**16 進**を指定します。`null` を渡すと既定色になります。

- **色名**（いずれも文字列）：
  `red` `pink` `purple` `deepPurple` `indigo` `blue` `lightBlue` `cyan` `teal`
  `green` `lightGreen` `lime` `yellow` `amber` `orange` `deepOrange`
  `brown` `grey` `blueGrey` `black` `white`
- **16 進**：`"#RRGGBB"`（例 `"#1E88E5"`）または不透明度付き `"#AARRGGBB"`（例 `"#80FF0000"` = 半透明の赤）

```dart
color: "green"
background: "#FFF59D"
iconColor: "#80FF0000"
```

---

## 12. アイコンの指定方法

`icon` には次の名前（文字列）が使えます。`null` を渡すとアイコン無しです。すべて枠線（アウトライン）です。

| 名前 | 見た目 |
|---|---|
| `cross` | ×（バツ） |
| `circle` | ○（丸） |
| `double_circle` | ◎（二重丸） |
| `check` | ✓（チェック） |
| `star` | ☆（星） |
| `favorite` | ♡（ハート） |
| `flag` | ⚑（旗） |
| `arrow_upward` | ↑ |
| `arrow_downward` | ↓ |

```dart
icon: "double_circle", iconColor: "green"
```

---

## 13. カラーマップ関数（数値→色）

数値の大小を色で表したいとき（ヒートマップ）に使える関数があります。戻り値は色の文字列なので、
`color` / `background` / `iconColor` にそのまま渡せます。

| 関数 | 戻り | 説明 |
|---|---|---|
| `heat(値, {min: 最小, max: 最大})` | String | `min`〜`max` を 低い=赤 … 高い=緑 に対応付け |
| `lerpColor(色A, 色B, t)` | String | 色 A と色 B を `t`（0.0〜1.0）で混ぜる |

```dart
// スピードの高さを背景のヒートマップに
dynamic display(CharaRecord r) {
  final s = r.status.speed;
  return Cell("$s", sort: s, background: heat(s, min: 600, max: 1800));
}

// 2 色グラデーション（青→赤）
background: lerpColor("blue", "red", 0.3)
```

> 段階的に色を分けたいだけなら、関数を使わず三項演算子でも書けます。ただし**両方の分岐が色（文字列）**のときだけです：
> `color: v >= 1500 ? "green" : "red"`（OK）。
> 片方を「既定（色なし）」にしたいときは `null` ではなく **`when(...)`** を使ってください（[16 章](#16-使える書き方避ける書き方)）。

---

## 14. 並べ替え（ソート）の仕組み

列ヘッダのクリックで並べ替えできます。並べ替えのキーは次のように決まります。

- すべての行が**並べ替えキーを持つ**場合（`display` が数値を返す、または `Cell(sort: ...)` を指定）
  → その**キーで並べ替え**（数値なら数値順、文字列なら辞書順）。数値のキーの列は右寄せ表示になります。
- それ以外 → **表示文字列の辞書順**。

`Cell` の `sort` には数値だけでなく**文字列**も渡せます（独自の並び順キーにしたいとき）。

```dart
// 表示は "A"〜"G" だが、並びは内部ランク（数値）で
dynamic display(CharaRecord r) {
  final c = r.aptitudes.distance.long;   // $Coded
  return Cell(c.name, sort: c.code);     // 表示=ランク文字、並び=ランクの大きさ
}
```

---

## 15. チェックと保存・エラー表示

- **「チェック」ボタン**：先頭の数件（約 20 件）に対して実際に実行し、**テーブルでの見え方**（各行の表示／色／アイコン）と
  **平均実行時間**を表示します。書きながら結果を確認できます。
- **コンパイルエラー**（文法ミスなど）：エラー内容が表示されます（コピー用ボタンあり）。
- **実行時エラー**（特定の行だけで起きる例外）：その行のセルだけ `⚠` になります（他の行は正常表示）。
- **保存（OK）はチェックが通るまで押せません。** コードを編集すると保存ボタンは再び無効になり、もう一度チェックが必要です。
  チェックが通ると「チェックOK。保存できます」と表示され、保存ボタンが有効になります
  （無限ループなどの危険なコードが保存されるのを防ぐ仕組みです）。
- **チェックが通らない条件**：コンパイルエラーがある／実行で例外が出る／処理が**重すぎる**
  （例：終わらないループ。`while (true) { }` のような無限ループはタイムアウトで弾かれます）。
  また、1 行あたりの実行時間 × 件数が大きすぎる場合は、表全体が遅くなるため警告されます。

---

## 16. 使える書き方・避ける書き方

### 使える書き方

- 変数：`final x = ...;`
- 演算子：`+ - * / %`、比較 `== != < <= > >=`、論理 `&& || !`、`?? ?. !`
- 三項演算子：`条件 ? A : B`（**両方の分岐に値があるとき**。片方を「無し」にしたいときは `when(...)`）
- 文字列：補間 `"…${式}…"`、`.contains("…")`、`==`
- `when(条件, 値)`：`条件` が真なら `値`、偽なら既定（`null`）。色・アイコン・`sort` の条件出し分けに使う
- ヘルパ関数・定数を同じ欄に定義して `filter`/`display` から呼ぶ
- メソッドのチェーン（`.where(...).map(...).sum` など）
- アロー記法 `=>`（`where((e) => ...)` のクロージャや、短い関数の定義に使えます）

### 避ける書き方（エラーや誤動作になります）

- **一覧に添字を使う**（`r.skills[0]` など）→ `.first` / `.firstOrNull` / `.where(...)` を使う
- **タグの一覧を直接取る** → `hasTag("…")` を使う（タグ名で判定）
- **`null` かもしれない値をそのまま比較する** → `!= null` で確かめるか `?? 既定値` を使う（[7 章](#7-null値が無いかもしれない項目の扱い)）
- **`!`（否定）を数値や `null` 許容値に付ける** → 比較（`== / >=` など）で `bool` にしてから使う
- **条件をいったん変数に入れて使い回す**（関数を値として持ち回る）→ 条件は式の中に直接書く（`&& || !` で合成）
- **`条件 ? 値 : null`（片方が `null` の三項演算子）** → 代わりに `when(条件, 値)` を使う
- **`Cell(...)` の中で、同じ数値変数を「その場の比較」と引数の両方に書く**
  （例 `Cell("$n", sort: n, color: when(n >= 6, "white"))`）→ 比較は**先に変数へ**：
  `final hot = n >= 6;` としてから `Cell("$n", sort: n, color: when(hot, "white"))`

---

## 17. レシピ集（そのまま使える例）

各レシピは `filter` と `display` をそのままコード欄に貼り付けて使えます。

### スピード上位だけを赤〜緑のヒートマップで

```dart
bool filter(CharaRecord r) {
  return r.status.speed >= 1000;
}

dynamic display(CharaRecord r) {
  final s = r.status.speed;
  return Cell("$s", sort: s, background: heat(s, min: 1000, max: 1800));
}
```

### スピード因子（本人＋親）が合計 4★以上

```dart
num speedStars(CharaRecord r) {
  return r.factorGroups.where((g) => g.name == "スピード").map((g) => g.totalStar).sum;
}

bool filter(CharaRecord r) {
  return speedStars(r) >= 4;
}

dynamic display(CharaRecord r) {
  return Cell("${speedStars(r).toInt()}★", sort: speedStars(r));
}
```

### 逃げスキルを持っていて、長距離適性が A

```dart
bool filter(CharaRecord r) {
  return r.skills.any((s) => s.hasTag("nige")) &&
      r.aptitudes.distance.long.name == "A";
}

dynamic display(CharaRecord r) {
  return r.skills.where((s) => s.hasTag("nige")).map((s) => s.name).join(", ");
}
```

### 芝のレースで勝った回数

```dart
bool filter(CharaRecord r) {
  return true;
}

dynamic display(CharaRecord r) {
  final n = r.races.where((e) => e.ground.name == "芝" && e.won).length;
  return Cell("$n 勝", sort: n);
}
```

### レーティングが 4.0 以上の行だけ、値を色付きで

```dart
bool filter(CharaRecord r) {
  return (r.ratings.get("main") ?? 0.0) >= 4.0;
}

dynamic display(CharaRecord r) {
  final v = r.ratings.get("main") ?? 0.0;
  final high = v >= 4.5;               // 条件は先に変数へ（16 章）
  return Cell(v.toStringAsFixed(1),
      sort: v,
      color: when(high, "white"),
      background: when(high, "green"));
}
```

### 所持スキルを全部「, 」で並べる

```dart
bool filter(CharaRecord r) {
  return true;
}

dynamic display(CharaRecord r) {
  return r.skills.map((s) => s.name).join(", ");
}
```

---

## 18. クイックリファレンス

```text
関数（必ず書く。中身は { return ...; } で書く）
  bool    filter(CharaRecord r)     行を表示するなら true
  dynamic display(CharaRecord r)    セルの内容（String / num / Cell / 一覧 / null）
  （ヘルパ関数・定数も同じ欄に定義可。両方から呼べる）

レコード r
  r.status / r.aptitudes / r.skills / r.factors / r.factorGroups / r.races
  r.supportCards / r.scenario / r.family / r.ratings / r.memos / r.metadata
  r.trainee($Coded) / r.charaRank($Coded)
  r.evaluationValue(int) / r.fans(int)
  r.trainedDate(String) / r.capturedDate(String) / r.id(String)

Status        speed stamina power guts intelligence（int）
Aptitudes     ground.{turf,dirt} / distance.{short,mile,middle,long}
              style.{leadPace,withPace,offPace,lateCharge}  …各々 $Coded（.name="A".. / .code=1..7）
Skill         id name level(int?) hasTag(name)
Factor        id name star subject($Coded) hasTag(name)
FactorGroup   id name totalStar selfStar parent1Star parent2Star hasTag(name)
Race          title($Coded) place position won(bool) ground/distance/strategy/weather($Coded)
SupportCard   id rank($Coded) level
Scenario      id name
Family        parent1/parent2 -> Parent{ self, parent1, parent2 ($Coded), rental(bool?) }
Ratings       get(key) -> double?
Memos         get(key) -> String?
Metadata      recordType($Coded) strategy($Coded) isFriend(bool)
$Coded        .name(ラベル) / .code(int、順序あり項目は大小比較可)
ID と code    すべて umacapture 内部の値（ゲーム内 ID ではない）。順序に意味なし・将来も不変。

一覧の操作
  .where((e)=>条件)  .whereNot((e)=>条件)  .any(...)  .every(...)
  .length  .isEmpty  .isNotEmpty  .first（空でエラー）  .firstOrNull（空でnull）
  .map((e)=>値) -> 値の一覧：.sum .max .min .average .length .join([区切り])

null 対策   x ?? 既定値 ／ x?.プロパティ ／ (x != null && x! ...)

Cell        Cell(文字列, {sort:, color:, background:, icon:, iconColor:})
色          色名（red green blue amber teal … white black）または "#RRGGBB" / "#AARRGGBB"
アイコン     cross circle double_circle check star favorite flag
            arrow_upward arrow_downward （すべて枠線）
カラーマップ heat(値,{min:,max:}) -> 色 ／ lerpColor(色A,色B,t) -> 色
条件出し分け when(条件, 値) -> 条件が真なら値・偽なら既定（色/アイコン/sort の ? : null の代わり）
注意        Cell内で同じ数値を「比較」と「引数」に同時使用しない（比較は先に final 変数へ）
```
