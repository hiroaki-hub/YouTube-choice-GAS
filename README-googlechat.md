# YouTube Choice BOT — Google Chat 版

`youtube-choice-gas-googlechat.jsp` は、`youtube-choce-gas.jsp` と同じロジックで、**通知先を Google Chat（Incoming Webhook）** にした版です。

## Discord 版との違い

| 項目 | Discord 版 | Google Chat 版 |
|------|------------|------------------|
| 通知 URL | `DISCORD_WEBHOOK_URL` | `GOOGLE_CHAT_WEBHOOK_URL` |
| 送信形式 | Discord Embeds | Chat `cardsV2` + ボタン |
| 対話（スラッシュ等） | Cloudflare Worker + `WEBHOOK_SECRET` | Chat アプリの **HTTP エンドポイント**（`doPost`）※任意 |
| 重複管理シート | `sent_videos`（既定） | `sent_videos_googlechat`（既定）※プロパティで変更可 |

## スクリプトプロパティ（必須）

| プロパティ | 説明 |
|------------|------|
| `YOUTUBE_API_KEY` | YouTube Data API v3 キー |
| `KIE_API_KEY` | KIE AI の API キー |
| `GOOGLE_CHAT_WEBHOOK_URL` | Google Chat スペースの **Incoming Webhook** で発行した URL |
| `SPREADSHEET_ID` | 送信済み `video_id` を記録するスプレッドシート ID |

## スクリプトプロパティ（任意）

| プロパティ | 説明 |
|------------|------|
| `SHEET_NAME` | 未設定時は `sent_videos_googlechat` |
| `CHAT_ENDPOINT_SECRET` | Chat アプリのボット URL に `?secret=値` を付ける場合、その値と一致させる |

## 初回手順

1. GAS に `youtube-choice-gas-googlechat.jsp` の内容をコピー（またはプロジェクトに追加）。
2. 上記プロパティを設定。
3. `setupSheet()` を一度手動実行（シート作成）。
4. 時間主トリガーで `notifyDailyAIVideo` を登録（例: 毎日 7:00）。

## Incoming Webhook のみの場合

- **毎朝の自動通知**だけ使うなら、Webhook URL と上記プロパティがあれば十分です。
- `doPost` はデプロイ不要（Web アプリにしなくてよい）。

## Chat アプリで「メンション／メッセージで検索」も使う場合

1. Google Cloud で Chat API を有効化し、**Chat アプリ**を作成。
2. **HTTP エンドポイント**に、この GAS の **Web アプリ URL**（`/exec`）を登録。
3. （推奨）エンドポイント URL に `?secret=あなたの秘密文字列` を付与し、スクリプトプロパティ `CHAT_ENDPOINT_SECRET` に同じ値を設定。
4. ボットをスペースに追加し、メッセージを送ると `runRequestSearchGoogleChat` が非同期で動き、結果は **同じ Incoming Webhook** へ投稿されます。

※ Chat からの HTTP リクエストの厳密な署名検証は別途（Google の推奨手順）を参照してください。`CHAT_ENDPOINT_SECRET` は簡易的なガードです。

## 手動テスト

エディタから `manualSearchSample()` を実行すると、キーワード「生成AI 最新」で 1 本選定して Chat に送ります。
