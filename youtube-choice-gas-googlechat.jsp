// =============================================================
// YouTube Choice BOT — Google Chat 版
// 基: youtube-choce-gas.jsp（Discord 版）を Google Chat Webhook 向けに変換
// =============================================================

// ===== エラー通知（Google Chat + Logger） =====
function notifyError(context, error, cfg) {
  var msg = 'BOTエラー [' + context + ']\n' + error.message + '\n' + ((error.stack || '').slice(0, 300));
  Logger.log(context + ': ' + error.message);
  try { postRawGoogleChat(msg, cfg); } catch (_) {}
}

// ===== 設定をスクリプトプロパティから安全に取得 =====
function getConfig() {
  var props = PropertiesService.getScriptProperties().getProperties();
  var required = ['YOUTUBE_API_KEY', 'KIE_API_KEY', 'GOOGLE_CHAT_WEBHOOK_URL', 'SPREADSHEET_ID'];
  required.forEach(function(key) {
    if (!props[key]) throw new Error('スクリプトプロパティ "' + key + '" が未設定です');
  });
  return {
    YOUTUBE_API_KEY:         props.YOUTUBE_API_KEY,
    KIE_API_KEY:             props.KIE_API_KEY,
    GOOGLE_CHAT_WEBHOOK_URL: props.GOOGLE_CHAT_WEBHOOK_URL,
    SPREADSHEET_ID:          props.SPREADSHEET_ID,
    CHAT_ENDPOINT_SECRET:    props.CHAT_ENDPOINT_SECRET || '',
    SHEET_NAME:              props.SHEET_NAME || 'sent_videos_googlechat',
    KIE_ENDPOINT: props.KIE_ENDPOINT || 'https://api.kie.ai/gemini-3-flash/v1/chat/completions',
    KIE_MODEL:    props.KIE_MODEL || 'gemini-3-flash',
  };
}

// =============================================
// 【モードA】毎朝7時の自動ピックアップ
// =============================================
var DAILY_QUERY_KEYS = ['DAILY_QUERIES_SUN', 'DAILY_QUERIES_MON', 'DAILY_QUERIES_TUE', 'DAILY_QUERIES_WED', 'DAILY_QUERIES_THU', 'DAILY_QUERIES_FRI', 'DAILY_QUERIES_SAT'];
var DAILY_QUERY_DEFAULTS = {
  DAILY_QUERIES_SUN: 'Claude Code 入門 使い方',
  DAILY_QUERIES_MON: 'Claude Code 新機能 最新',
  DAILY_QUERIES_TUE: 'Claude Code MCP 拡張機能',
  DAILY_QUERIES_WED: 'Claude Code Cursor 連携 使い方',
  DAILY_QUERIES_THU: 'Claude Code 自動化 AIエージェント',
  DAILY_QUERIES_FRI: 'Claude Code 実践 チュートリアル',
  DAILY_QUERIES_SAT: 'Anthropic Claude コーディング Tips',
};

var TZ_TOKYO = 'Asia/Tokyo';

function getJpDayOfWeek() {
  var u = Number(Utilities.formatDate(new Date(), TZ_TOKYO, 'u'));
  return u % 7;
}

function formatJpDate(date) {
  return Utilities.formatDate(date, TZ_TOKYO, 'yyyy/MM/dd');
}

function formatJpDateTime(date) {
  return Utilities.formatDate(date, TZ_TOKYO, 'yyyy/MM/dd HH:mm:ss');
}

function getDailyQuery() {
  var props = PropertiesService.getScriptProperties().getProperties();
  var key = DAILY_QUERY_KEYS[getJpDayOfWeek()];
  var value = props[key];
  if (value && value.trim()) return value.trim();
  return DAILY_QUERY_DEFAULTS[key];
}

function notifyDailyAIVideo() {
  try {
    var cfg = getConfig();
    var sentIds = getSentVideoIds(cfg);
    var query = getDailyQuery();
    var rawVideos = searchYouTube(query, sentIds, 20, cfg);
    if (!rawVideos.length) { Logger.log('新しい動画なし'); return; }
    var videos = sortByViewCount(enrichWithStats(rawVideos, cfg));

    var picked = judgeWithKieAI(
      videos, 1,
      '実用Tips系と最新技術系をバランスよく考慮し、最も独自性・面白さがある動画を1本',
      cfg
    );
    if (!picked.length) return;

    postToGoogleChat(picked, '🌅 今日のAI動画｜AI自動ピックアップ｜🔎 ' + query, cfg);
    saveSentVideoIds(picked.map(function(v) { return v.videoId; }), cfg);
  } catch (e) {
    notifyError('モードA', e, getConfig());
  }
}

// =============================================
// 【モードB】Google Chat アプリ HTTP エンドポイント
// =============================================
function doPost(e) {
  try {
    var cfg = getConfig();
    if (cfg.CHAT_ENDPOINT_SECRET) {
      var sec = (e.parameter && e.parameter.secret) ? e.parameter.secret : '';
      if (sec !== cfg.CHAT_ENDPOINT_SECRET) {
        return ContentService.createTextOutput('unauthorized').setMimeType(ContentService.MimeType.TEXT);
      }
    }

    var body = JSON.parse(e.postData.contents);

    // --- 旧形式（Apps Script 接続）---
    if (body.type === 'URL_VERIFICATION') {
      return ContentService
        .createTextOutput(JSON.stringify({ token: body.token }))
        .setMimeType(ContentService.MimeType.JSON);
    }
    if (body.type === 'MESSAGE' && body.message) {
      return handleChatMessage(
        (body.message.argumentText || body.message.text || '').trim(),
        (body.user && body.user.displayName) ? body.user.displayName : 'ユーザー',
        cfg
      );
    }

    // --- 新形式（HTTP エンドポイント接続 / Workspace Add-ons）---
    var chat = body.chat || {};
    if (chat.messagePayload) {
      var msg = chat.messagePayload.message || {};
      var rawText = (msg.argumentText || msg.text || '').trim();
      var sender = 'ユーザー';
      if (msg.sender && msg.sender.displayName) sender = msg.sender.displayName;
      return handleChatMessage(rawText, sender, cfg);
    }

    return ContentService.createTextOutput(JSON.stringify({
      text: 'イベントを受信しました。'
    })).setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    Logger.log('doPostエラー: ' + err.message);
    return ContentService
      .createTextOutput(JSON.stringify({ text: 'エラーが発生しました。しばらくしてから再度お試しください。' }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}

function handleChatMessage(rawText, sender, cfg) {
  if (!rawText) {
    postRawGoogleChat('キーワードを入力してください。', cfg);
    return ContentService.createTextOutput('{}').setMimeType(ContentService.MimeType.JSON);
  }

  postRawGoogleChat('🔍 ' + sender + ' さんのリクエストを受け付けました。すぐ探します…', cfg);

  var pendingKey = 'PENDING_GC_' + Date.now();
  PropertiesService.getScriptProperties().setProperty(
    pendingKey,
    JSON.stringify({ keyword: rawText, sender: sender, ts: new Date().toISOString() })
  );
  ScriptApp.newTrigger('runRequestSearchGoogleChat').timeBased().after(1000).create();

  return ContentService.createTextOutput('{}').setMimeType(ContentService.MimeType.JSON);
}

// リクエスト検索の実処理（非同期トリガー経由）
function runRequestSearchGoogleChat() {
  ScriptApp.getProjectTriggers()
    .filter(function(t) { return t.getHandlerFunction() === 'runRequestSearchGoogleChat'; })
    .forEach(function(t) { ScriptApp.deleteTrigger(t); });

  var cfg = getConfig();
  var props = PropertiesService.getScriptProperties();
  var allProps = props.getProperties();
  var allKeys = Object.keys(allProps).filter(function(k) { return k.indexOf('PENDING_GC_') === 0; });

  if (!allKeys.length) return;

  allKeys.forEach(function(key) {
    try {
      var data = JSON.parse(props.getProperty(key));
      props.deleteProperty(key);

      var searchQuery = extractSearchKeyword(data.keyword, cfg);
      var sentIds = getSentVideoIds(cfg);
      var rawVideos = searchYouTube(searchQuery, sentIds, 15, cfg);

      if (!rawVideos.length) {
        postRawGoogleChat('😢 「' + searchQuery + '」に関する新着動画が見つかりませんでした。', cfg);
        return;
      }
      var videos = sortByViewCount(enrichWithStats(rawVideos, cfg));

      var picked = judgeWithKieAI(
        videos, 1,
        '「' + searchQuery + '」というテーマで最も参考になる・面白い動画を1本',
        cfg
      );
      if (!picked.length) return;

      postToGoogleChat(picked, '📬 ' + data.sender + ' さんのリクエスト「' + searchQuery + '」', cfg);
      saveSentVideoIds(picked.map(function(v) { return v.videoId; }), cfg);
    } catch (err) {
      notifyError('runRequestSearchGoogleChat', err, cfg);
    }
  });
}

// =============================================
// 手動テスト用（エディタから実行）
// =============================================
function manualSearchSample() {
  var cfg = getConfig();
  var pendingKey = 'PENDING_GC_' + Date.now();
  PropertiesService.getScriptProperties().setProperty(
    pendingKey,
    JSON.stringify({ keyword: '生成AI 最新', sender: '手動テスト', ts: new Date().toISOString() })
  );
  runRequestSearchGoogleChat();
}

// 指定クエリキーで動作確認（共通処理）
function _testDailyQueryByKey(key) {
  try {
    var cfg = getConfig();
    var props = PropertiesService.getScriptProperties().getProperties();
    var query = (props[key] && props[key].trim()) ? props[key].trim() : DAILY_QUERY_DEFAULTS[key];
    Logger.log('[テスト] クエリキー: ' + key + ' / クエリ: ' + query);
    var sentIds = getSentVideoIds(cfg);
    var rawVideos = searchYouTube(query, sentIds, 20, cfg);
    if (!rawVideos.length) {
      postRawGoogleChat('【テスト: ' + key + '】😢 「' + query + '」に関する新着動画が見つかりませんでした。', cfg);
      return;
    }
    var videos = sortByViewCount(enrichWithStats(rawVideos, cfg));
    var picked = judgeWithKieAI(
      videos, 1,
      '実用Tips系と最新技術系をバランスよく考慮し、最も独自性・面白さがある動画を1本',
      cfg
    );
    if (!picked.length) return;
    postToGoogleChat(picked, '🧪 テスト投稿【' + key + '】クエリ: ' + query, cfg);
    Logger.log('[テスト完了] ' + key + ' → ' + picked[0].title);
  } catch (e) {
    notifyError('testDailyQuery_' + key, e, getConfig());
  }
}

function testQuerySun() { _testDailyQueryByKey('DAILY_QUERIES_SUN'); }  // 日: Claude Code 入門 使い方
function testQueryMon() { _testDailyQueryByKey('DAILY_QUERIES_MON'); }  // 月: Claude Code 新機能 最新
function testQueryTue() { _testDailyQueryByKey('DAILY_QUERIES_TUE'); }  // 火: Claude Code MCP 拡張機能
function testQueryWed() { _testDailyQueryByKey('DAILY_QUERIES_WED'); }  // 水: Claude Code Cursor 連携 使い方
function testQueryThu() { _testDailyQueryByKey('DAILY_QUERIES_THU'); }  // 木: Claude Code 自動化 AIエージェント
function testQueryFri() { _testDailyQueryByKey('DAILY_QUERIES_FRI'); }  // 金: Claude Code 実践 チュートリアル
function testQuerySat() { _testDailyQueryByKey('DAILY_QUERIES_SAT'); }  // 土: Anthropic Claude コーディング Tips

// =============================================
// 共通：YouTube 検索
// =============================================
function searchYouTube(query, sentIds, maxResults, cfg) {
  var since = new Date();
  since.setMonth(since.getMonth() - 3);

  var url = 'https://www.googleapis.com/youtube/v3/search'
    + '?part=snippet&type=video&order=relevance&videoCategoryId=28'
    + '&q=' + encodeURIComponent(query)
    + '&publishedAfter=' + since.toISOString()
    + '&maxResults=' + maxResults
    + '&regionCode=JP&relevanceLanguage=ja'
    + '&key=' + cfg.YOUTUBE_API_KEY;

  var res = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (res.getResponseCode() !== 200) {
    throw new Error('YouTube API ' + res.getResponseCode() + ': ' + res.getContentText().slice(0, 200));
  }
  var data = JSON.parse(res.getContentText());
  return (data.items || [])
    .filter(function(item) { return !sentIds.has(item.id.videoId); })
    .map(function(item) {
      var thumbs = item.snippet.thumbnails || {};
      return {
        videoId:      item.id.videoId,
        title:        item.snippet.title,
        description:  item.snippet.description.slice(0, 400),
        publishedAt:  item.snippet.publishedAt,
        channelTitle: item.snippet.channelTitle,
        thumbnail:    (thumbs.high && thumbs.high.url) || (thumbs['default'] && thumbs['default'].url) || '',
        url: 'https://www.youtube.com/watch?v=' + item.id.videoId
      };
    });
}

// =============================================
// 共通：動画の統計情報（再生回数・高評価・尺）を補完
// =============================================
function enrichWithStats(videos, cfg) {
  if (!videos.length) return videos;
  var ids = videos.map(function(v) { return v.videoId; }).join(',');
  var url = 'https://www.googleapis.com/youtube/v3/videos'
    + '?part=statistics,contentDetails&id=' + ids + '&key=' + cfg.YOUTUBE_API_KEY;
  var res = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (res.getResponseCode() !== 200) {
    Logger.log('videos.list APIエラー: ' + res.getResponseCode());
    return videos;
  }
  var data = JSON.parse(res.getContentText());
  var statsMap = {};
  (data.items || []).forEach(function(item) {
    statsMap[item.id] = {
      viewCount: Number(item.statistics.viewCount || 0),
      likeCount: Number(item.statistics.likeCount || 0),
      duration:  item.contentDetails.duration
    };
  });
  return videos.map(function(v) {
    var s = statsMap[v.videoId] || {};
    return {
      videoId: v.videoId, title: v.title, description: v.description,
      publishedAt: v.publishedAt, channelTitle: v.channelTitle,
      thumbnail: v.thumbnail, url: v.url,
      viewCount: s.viewCount, likeCount: s.likeCount, duration: s.duration
    };
  });
}

function sortByViewCount(videos) {
  return videos.slice().sort(function(a, b) {
    return (b.viewCount || 0) - (a.viewCount || 0);
  });
}

function formatDuration(iso) {
  if (!iso) return '不明';
  var m = iso.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/);
  if (!m) return iso;
  var h = m[1] ? m[1] + '時間' : '';
  var min = m[2] ? m[2] + '分' : '';
  var s = m[3] ? m[3] + '秒' : '';
  return (h + min + s) || '0秒';
}

function formatViewCount(n) {
  if (n == null) return '不明';
  if (n >= 10000) return (n / 10000).toFixed(1) + '万回';
  return n.toLocaleString() + '回';
}

// KIE AI Gemini 3 Flash（OpenAI互換 chat/completions）の assistant 本文を取得
function kieOpenAiExtractMessageText(result) {
  var ch = result.choices && result.choices[0] && result.choices[0].message;
  if (!ch || ch.content == null) return '';
  var c = ch.content;
  if (typeof c === 'string') return c;
  if (c.length !== undefined) {
    var out = [];
    for (var i = 0; i < c.length; i++) {
      var p = c[i];
      if (p && p.type === 'text' && p.text) out.push(p.text);
    }
    return out.join('');
  }
  return '';
}

// =============================================
// 共通：KIE AI（Gemini 3 Flash / OpenAI互換）で動画選定
// =============================================
function judgeWithKieAI(videos, count, instruction, cfg) {
  var list = videos.map(function(v, i) {
    var parts = ['[' + (i + 1) + '] タイトル: ' + v.title, 'チャンネル: ' + v.channelTitle];
    if (v.viewCount != null) parts.push('再生回数: ' + formatViewCount(v.viewCount));
    if (v.likeCount != null && v.likeCount > 0) parts.push('高評価数: ' + v.likeCount);
    if (v.duration) parts.push('動画の長さ: ' + formatDuration(v.duration));
    if (v.description) parts.push('概要: ' + v.description);
    return parts.join('\n');
  }).join('\n\n');

  var prompt = '以下の動画リストから、' + instruction + 'を選んでください。\n\n'
    + '選定基準:\n'
    + '- 日本語の動画を最優先で選ぶこと（タイトル・チャンネル名が日本語の動画を優先。英語タイトルの海外動画は日本語の候補がない場合のみ選ぶ）\n'
    + '- 初級〜中級者でも理解しやすく、分かりやすい説明がある動画を優先\n'
    + '- 実演・画面操作・ハンズオンなど「見ればマネできる」内容を高く評価\n'
    + '- 入門・使い方・活用法・実践Tipsなど、すぐ役立つ内容を重視\n'
    + '- ニュース報道・速報・ストレートニュースは避ける（解説・考察を含むニュースはOK）\n'
    + '- 再生回数・高評価数が多い動画は視聴者の満足度が高い可能性があるので考慮する\n'
    + '- 再生回数が多くても内容が薄い・タイトル詐欺の動画は避ける\n'
    + '- 10分未満の短い動画・30分を超える長尺動画は避ける（10〜30分が理想）\n'
    + '- 単なる宣伝・製品紹介だけの動画は避ける\n'
    + '- できるだけ異なるチャンネルから選ぶ\n\n'
    + '【動画リスト】\n' + list + '\n\n'
    + '以下のJSONのみ返してください（前後の説明不要）:\n'
    + '[{"index": 番号, "reason": "選んだ理由を日本語2〜3文で"}]';

  var res = UrlFetchApp.fetch(cfg.KIE_ENDPOINT, {
    method: 'POST',
    muteHttpExceptions: true,
    headers: {
      'Content-Type':  'application/json',
      'Authorization': 'Bearer ' + cfg.KIE_API_KEY
    },
    payload: JSON.stringify({
      model: cfg.KIE_MODEL,
      max_tokens: 1000,
      stream: false,
      include_thoughts: false,
      messages: [
        { role: 'system', content: 'あなたはAI活用の動画キュレーターです。初級〜中級者にとって分かりやすく役に立つ動画を選ぶのが得意です。指示されたJSON形式のみを返してください。前後の説明は一切不要です。' },
        { role: 'user', content: prompt }
      ]
    })
  });

  if (res.getResponseCode() !== 200) {
    Logger.log('KIE AI APIエラー: ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 300));
    var fb = {}; for (var k in videos[0]) fb[k] = videos[0][k];
    fb.reason = '（AI選定APIがエラーのため先頭の動画を自動選出）';
    return [fb].slice(0, count);
  }

  var picks;
  try {
    var rawText = res.getContentText();
    var result = JSON.parse(rawText);
    var aiText = kieOpenAiExtractMessageText(result);
    if (!aiText) {
      Logger.log('AI応答の構造が不明: ' + rawText.slice(0, 500));
      throw new Error('未知の応答形式');
    }
    var text = aiText.trim().replace(/```json|```/g, '').trim();
    picks = JSON.parse(text);
  } catch (parseErr) {
    Logger.log('AI応答のパースに失敗: ' + parseErr.message);
    Logger.log('AI応答(先頭500文字): ' + res.getContentText().slice(0, 500));
    var fb2 = {}; for (var k2 in videos[0]) fb2[k2] = videos[0][k2];
    fb2.reason = '（AI応答の解析に失敗したため先頭の動画を自動選出）';
    return [fb2].slice(0, count);
  }

  return picks
    .filter(function(p) {
      return typeof p.index === 'number' && p.index >= 1 && p.index <= videos.length && p.index === Math.floor(p.index);
    })
    .slice(0, count)
    .map(function(p) {
      var v = videos[p.index - 1];
      var out = {}; for (var k3 in v) out[k3] = v[k3];
      out.reason = p.reason || '理由なし';
      return out;
    });
}

// =============================================
// 共通：KIE AI でキーワード抽出
// =============================================
function extractSearchKeyword(text, cfg) {
  var userContent = '現在は' + Utilities.formatDate(new Date(), TZ_TOKYO, 'yyyy') + '年です。次のメッセージからYouTube検索キーワードを10語以内で抽出。元のメッセージにない年号は追加しないでください。\n"' + text + '"';
  var res = UrlFetchApp.fetch(cfg.KIE_ENDPOINT, {
    method: 'POST',
    muteHttpExceptions: true,
    headers: {
      'Content-Type':  'application/json',
      'Authorization': 'Bearer ' + cfg.KIE_API_KEY
    },
    payload: JSON.stringify({
      model: cfg.KIE_MODEL,
      max_tokens: 120,
      stream: false,
      include_thoughts: false,
      reasoning_effort: 'low',
      messages: [
        { role: 'system', content: 'YouTube検索に最適なキーワードのみを返してください。説明は不要です。ルール: ユーザーの言葉にない年号(2024,2025等)を勝手に追加しないこと。' },
        { role: 'user', content: userContent }
      ]
    })
  });
  if (res.getResponseCode() !== 200) {
    Logger.log('キーワード抽出APIエラー: ' + res.getResponseCode());
    return text;
  }
  try {
    var result = JSON.parse(res.getContentText());
    var aiText = kieOpenAiExtractMessageText(result);
    return (aiText || text).trim();
  } catch (e) {
    Logger.log('キーワード抽出のパース失敗: ' + e.message);
    return text;
  }
}

// =============================================
// Google Chat Incoming Webhook（cardsV2 カード形式）
// =============================================
function escapeChatHtml(s) {
  if (s == null || s === '') return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function postToGoogleChat(videos, header, cfg) {
  var date = formatJpDate(new Date());
  var cardsV2 = videos.map(function(v, idx) {
    var pub = formatJpDate(new Date(v.publishedAt));
    var subParts = [escapeChatHtml(v.channelTitle), pub];
    if (v.viewCount != null) subParts.push(formatViewCount(v.viewCount));
    if (v.duration) subParts.push(formatDuration(v.duration));
    var reasonHtml = '<b>💡 選定理由</b><br>' + escapeChatHtml(v.reason);
    var descHtml = '';
    if (v.description) {
      descHtml = '<br><br><b>概要</b><br>' + escapeChatHtml(v.description.slice(0, 280));
      if (v.description.length > 280) descHtml += '…';
    }
    var widgets = [
      { textParagraph: { text: reasonHtml + descHtml } },
      {
        buttonList: {
          buttons: [
            {
              text: 'YouTubeで開く',
              onClick: { openLink: { url: v.url } }
            }
          ]
        }
      }
    ];
    var cardHeader = {
      title: escapeChatHtml(v.title),
      subtitle: subParts.join(' ｜ ')
    };
    if (v.thumbnail) cardHeader.imageUrl = v.thumbnail;
    return {
      cardId: 'yt-' + v.videoId + '-' + idx,
      card: {
        header: cardHeader,
        sections: [{ widgets: widgets }]
      }
    };
  });

  var payload = {
    text: header + ' ｜ ' + date,
    cardsV2: cardsV2
  };

  var res = UrlFetchApp.fetch(cfg.GOOGLE_CHAT_WEBHOOK_URL, {
    method: 'POST',
    contentType: 'application/json; charset=utf-8',
    muteHttpExceptions: true,
    payload: JSON.stringify(payload)
  });
  if (res.getResponseCode() >= 400) {
    Logger.log('Google Chat 送信エラー: ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 300));
  }
}

function postRawGoogleChat(text, cfg) {
  var res = UrlFetchApp.fetch(cfg.GOOGLE_CHAT_WEBHOOK_URL, {
    method: 'POST',
    contentType: 'application/json; charset=utf-8',
    muteHttpExceptions: true,
    payload: JSON.stringify({ text: text })
  });
  if (res.getResponseCode() >= 400) {
    Logger.log('Google Chat 送信エラー: ' + res.getResponseCode());
  }
}

// =============================================
// スプレッドシート操作
// =============================================
function getSentVideoIds(cfg) {
  var sheet = SpreadsheetApp.openById(cfg.SPREADSHEET_ID)
    .getSheetByName(cfg.SHEET_NAME);
  if (!sheet || sheet.getLastRow() < 2) return new Set();
  var ids = sheet.getRange(2, 1, sheet.getLastRow() - 1, 1)
    .getValues().flat().filter(Boolean);
  return new Set(ids);
}

function saveSentVideoIds(videoIds, cfg) {
  var sheet = SpreadsheetApp.openById(cfg.SPREADSHEET_ID)
    .getSheetByName(cfg.SHEET_NAME);
  var now = formatJpDateTime(new Date());
  videoIds.forEach(function(id) { sheet.appendRow([id, now]); });
}

// =============================================
// メンテナンス：3ヶ月以上前の送信済みレコードを削除
// =============================================
function cleanupOldRecords() {
  var cfg = getConfig();
  var sheet = SpreadsheetApp.openById(cfg.SPREADSHEET_ID)
    .getSheetByName(cfg.SHEET_NAME);
  if (!sheet || sheet.getLastRow() < 2) return;

  var threeMonthsAgo = new Date();
  threeMonthsAgo.setMonth(threeMonthsAgo.getMonth() - 3);

  var data = sheet.getRange(2, 1, sheet.getLastRow() - 1, 2).getValues();
  var rowsToDelete = [];
  data.forEach(function(row, i) {
    if (new Date(row[1]) < threeMonthsAgo) rowsToDelete.push(i + 2);
  });
  rowsToDelete.reverse().forEach(function(r) { sheet.deleteRow(r); });
  Logger.log('cleanupOldRecords: ' + rowsToDelete.length + '件の古いレコードを削除');
}

// =============================================
// 初回セットアップ（1回だけ手動実行）
// =============================================
function setupSheet() {
  var cfg = getConfig();
  var ss = SpreadsheetApp.openById(cfg.SPREADSHEET_ID);
  if (!ss.getSheetByName(cfg.SHEET_NAME)) {
    var s = ss.insertSheet(cfg.SHEET_NAME);
    s.getRange(1, 1, 1, 2).setValues([['video_id', 'sent_at']]);
  }
  Logger.log('セットアップ完了（シート: ' + cfg.SHEET_NAME + '）');
}

function doGet(e) {
  return ContentService
    .createTextOutput('YouTube Choice BOT (Google Chat) is running.')
    .setMimeType(ContentService.MimeType.TEXT);
}
