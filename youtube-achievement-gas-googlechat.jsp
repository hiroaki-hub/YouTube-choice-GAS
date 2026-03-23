// =============================================================
// YouTube Achievement BOT — Google Chat 版
// 対象チャンネル: https://www.youtube.com/@satoshi-aoki
// 1日1動画をテーマ別に紹介（モードAのみ）
// =============================================================

// ===== エラー通知（Google Chat + Logger） =====
function sanitizeErrorMessage(msg) {
  return (msg || '').replace(/key=[A-Za-z0-9_-]+/gi, 'key=***').replace(/Bearer [A-Za-z0-9_-]+/gi, 'Bearer ***');
}

function notifyError(context, error, cfgOrNull) {
  var safeMsg = sanitizeErrorMessage(error.message);
  var safeStack = sanitizeErrorMessage((error.stack || '').slice(0, 300));
  Logger.log(context + ': ' + error.message);
  try {
    var cfg = cfgOrNull || getConfig();
    postRawGoogleChat('BOTエラー [' + context + ']\n' + safeMsg + '\n' + safeStack, cfg);
  } catch (_) {}
}

// ===== 設定をスクリプトプロパティから安全に取得 =====
function getConfig() {
  var props = PropertiesService.getScriptProperties().getProperties();
  var required = ['YOUTUBE_API_KEY', 'KIE_API_KEY', 'GOOGLE_CHAT_WEBHOOK_URL', 'SPREADSHEET_ID', 'CHANNEL_ID'];
  required.forEach(function(key) {
    if (!props[key]) throw new Error('スクリプトプロパティ "' + key + '" が未設定です');
  });
  return {
    YOUTUBE_API_KEY:         props.YOUTUBE_API_KEY,
    KIE_API_KEY:             props.KIE_API_KEY,
    GOOGLE_CHAT_WEBHOOK_URL: props.GOOGLE_CHAT_WEBHOOK_URL,
    SPREADSHEET_ID:          props.SPREADSHEET_ID,
    CHANNEL_ID:              props.CHANNEL_ID,
    SHEET_NAME:              'sent_videos_achievement',
    KIE_ENDPOINT: props.KIE_ENDPOINT || 'https://api.kie.ai/gemini-3-flash/v1/chat/completions',
    KIE_MODEL:    props.KIE_MODEL || 'gemini-3-flash',
  };
}

// =============================================
// 【初回セットアップ】チャンネルIDを自動取得して保存
// 1回だけ手動実行してください
// =============================================
function setupChannelId() {
  var props = PropertiesService.getScriptProperties().getProperties();
  var apiKey = props['YOUTUBE_API_KEY'];
  if (!apiKey) throw new Error('YOUTUBE_API_KEY が未設定です');

  var url = 'https://www.googleapis.com/youtube/v3/channels'
    + '?part=id,snippet&forHandle=satoshi-aoki&key=' + apiKey;
  var res = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (res.getResponseCode() !== 200) {
    throw new Error('チャンネルID取得失敗: ' + sanitizeErrorMessage(res.getContentText().slice(0, 200)));
  }
  var data = JSON.parse(res.getContentText());
  if (!data.items || !data.items.length) {
    throw new Error('チャンネルが見つかりませんでした。ハンドル名を確認してください。');
  }
  var channelId = data.items[0].id;
  var channelTitle = data.items[0].snippet.title;
  PropertiesService.getScriptProperties().setProperty('CHANNEL_ID', channelId);
  Logger.log('チャンネルID取得完了: ' + channelTitle + ' / ' + channelId);
}

// =============================================
// 【初回セットアップ】シート作成（1回だけ手動実行）
// =============================================
function setupSheet() {
  var cfg = getConfig();
  var ss = SpreadsheetApp.openById(cfg.SPREADSHEET_ID);
  if (!ss.getSheetByName(cfg.SHEET_NAME)) {
    var s = ss.insertSheet(cfg.SHEET_NAME);
    s.getRange(1, 1, 1, 2).setValues([['video_id', 'sent_at']]);
    Logger.log('シート作成完了: ' + cfg.SHEET_NAME);
  } else {
    Logger.log('シートは既に存在します: ' + cfg.SHEET_NAME);
  }
}

// =============================================
// 曜日別テーマと検索キーワード
// =============================================
var DAILY_QUERY_KEYS = ['DAILY_QUERIES_SUN', 'DAILY_QUERIES_MON', 'DAILY_QUERIES_TUE', 'DAILY_QUERIES_WED', 'DAILY_QUERIES_THU', 'DAILY_QUERIES_FRI', 'DAILY_QUERIES_SAT'];
var DAILY_QUERY_DEFAULTS = {
  DAILY_QUERIES_SUN: '決断 意思決定 覚悟 リスク 経営判断 事業承継 撤退',
  DAILY_QUERIES_MON: '採用 面接 入社 求人 応募 選考 内定',
  DAILY_QUERIES_TUE: '離職 退職 辞める 定着 エンゲージメント 転職',
  DAILY_QUERIES_WED: '上司 部下 指導 叱る 1on1 フィードバック 信頼',
  DAILY_QUERIES_THU: '朝活 ルーティン 段取り 時間管理 早起き 効率 生産性',
  DAILY_QUERIES_FRI: 'キャリア 昇進 出世 市場価値 年収 評価 プロ',
  DAILY_QUERIES_SAT: '組織 チーム 文化 風土 理念浸透 一体感 会議',
};
var DAILY_THEME_LABELS = {
  DAILY_QUERIES_SUN: '経営判断・意思決定',
  DAILY_QUERIES_MON: '採用・面接',
  DAILY_QUERIES_TUE: '離職防止・定着',
  DAILY_QUERIES_WED: '上司力・部下指導',
  DAILY_QUERIES_THU: '目標・習慣・時間術',
  DAILY_QUERIES_FRI: '自己成長・キャリア',
  DAILY_QUERIES_SAT: '組織づくり・チーム',
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

function getDailyQueryInfo() {
  var props = PropertiesService.getScriptProperties().getProperties();
  var key = DAILY_QUERY_KEYS[getJpDayOfWeek()];
  var query = (props[key] && props[key].trim()) ? props[key].trim() : DAILY_QUERY_DEFAULTS[key];
  var label = DAILY_THEME_LABELS[key];
  return { query: query, label: label };
}

// =============================================
// 【モードA】毎朝の自動ピックアップ
// =============================================
function notifyDailyAchievementVideo() {
  var cfg = null;
  try {
    cfg = getConfig();
    var sentIds = getSentVideoIds(cfg);
    var info = getDailyQueryInfo();

    var videos = searchChannelVideos(info.query, sentIds, 50, cfg);
    if (!videos.length) {
      Logger.log('テーマ「' + info.label + '」の未送信動画なし → 全体から検索');
      videos = searchChannelVideos('', sentIds, 50, cfg);
    }
    if (!videos.length) {
      postRawGoogleChat('📭 本日のテーマ「' + info.label + '」に合う未送信の動画が見つかりませんでした。（送信済み: ' + sentIds.size + '件）', cfg);
      return;
    }

    videos = enrichWithStats(videos, cfg);
    var picked = judgeWithKieAI(videos, 1, info.label, cfg);
    if (!picked.length) {
      Logger.log('AI選定結果が0件でした');
      return;
    }

    var header = '📚 今日の青木仁志チャンネル｜' + info.label;
    postToGoogleChat(picked, header, cfg);
    saveSentVideoIds(picked.map(function(v) { return v.videoId; }), cfg);
  } catch (e) {
    notifyError('notifyDailyAchievementVideo', e, cfg);
  }
}

// =============================================
// 手動テスト用（エディタから実行）
// =============================================
function manualPickSample() {
  notifyDailyAchievementVideo();
}

function debugSearchTest() {
  var cfg = getConfig();
  Logger.log('CHANNEL_ID: ' + cfg.CHANNEL_ID);

  var baseUrl = 'https://www.googleapis.com/youtube/v3/search'
    + '?part=snippet&type=video&order=relevance'
    + '&channelId=' + cfg.CHANNEL_ID
    + '&maxResults=50'
    + '&key=' + cfg.YOUTUBE_API_KEY;

  var res0 = UrlFetchApp.fetch(baseUrl, { muteHttpExceptions: true });
  var data0 = JSON.parse(res0.getContentText());
  var total = (data0.pageInfo && data0.pageInfo.totalResults) || '不明';
  Logger.log('チャンネル総動画数(概算): ' + total);
  Logger.log('キーワードなし取得数: ' + ((data0.items || []).length));
  Logger.log('');

  var days = ['SUN(日)', 'MON(月)', 'TUE(火)', 'WED(水)', 'THU(木)', 'FRI(金)', 'SAT(土)'];
  DAILY_QUERY_KEYS.forEach(function(key, i) {
    if (i > 0) Utilities.sleep(2000);
    var keywords = DAILY_QUERY_DEFAULTS[key];
    var label = DAILY_THEME_LABELS[key];
    var orQuery = keywords.trim().split(/\s+/).join('|');
    var url = baseUrl + '&q=' + encodeURIComponent(orQuery);
    var res = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
    if (res.getResponseCode() !== 200) {
      Logger.log(days[i] + ' [' + label + '] APIエラー: ' + res.getResponseCode());
      return;
    }
    var data = JSON.parse(res.getContentText());
    var count = (data.items || []).length;
    var totalHits = (data.pageInfo && data.pageInfo.totalResults) || '?';
    Logger.log(days[i] + ' [' + label + '] ヒット: ' + count + '件 (総該当: ' + totalHits + ') ← ' + orQuery);
    (data.items || []).slice(0, 3).forEach(function(item, j) {
      Logger.log('  ' + (j+1) + '. ' + (item.snippet ? item.snippet.title : '?'));
    });
  });
}

// =============================================
// チャンネル内動画検索（全期間）
// =============================================
function searchChannelVideos(query, sentIds, maxResults, cfg) {
  var url = 'https://www.googleapis.com/youtube/v3/search'
    + '?part=snippet&type=video&order=relevance'
    + '&channelId=' + cfg.CHANNEL_ID
    + '&maxResults=' + maxResults
    + '&key=' + cfg.YOUTUBE_API_KEY;
  if (query) {
    var orQuery = query.trim().split(/\s+/).join('|');
    url += '&q=' + encodeURIComponent(orQuery);
  }

  var res = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (res.getResponseCode() !== 200) {
    throw new Error('YouTube API ' + res.getResponseCode() + ': ' + sanitizeErrorMessage(res.getContentText().slice(0, 200)));
  }
  var data = JSON.parse(res.getContentText());
  return (data.items || [])
    .filter(function(item) { return item.id && item.id.videoId && !sentIds.has(item.id.videoId); })
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
// 動画の統計情報（再生回数・尺）を補完
// =============================================
function enrichWithStats(videos, cfg) {
  if (!videos.length) return videos;
  var ids = videos.map(function(v) { return v.videoId; }).join(',');
  var url = 'https://www.googleapis.com/youtube/v3/videos'
    + '?part=statistics,contentDetails&id=' + ids + '&key=' + cfg.YOUTUBE_API_KEY;
  var res = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (res.getResponseCode() !== 200) {
    Logger.log('videos.list APIエラー: ' + res.getResponseCode() + ' ' + sanitizeErrorMessage(res.getContentText().slice(0, 200)));
    return videos;
  }
  var data = JSON.parse(res.getContentText());
  var statsMap = {};
  (data.items || []).forEach(function(item) {
    var stats = item.statistics || {};
    var details = item.contentDetails || {};
    statsMap[item.id] = {
      viewCount: Number(stats.viewCount || 0),
      likeCount: Number(stats.likeCount || 0),
      duration:  details.duration || ''
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
// KIE AI（Gemini 3 Flash / OpenAI互換）で動画選定
// =============================================
function judgeWithKieAI(videos, count, themeLabel, cfg) {
  var list = videos.map(function(v, i) {
    var parts = ['[' + (i + 1) + '] タイトル: ' + v.title];
    if (v.viewCount != null) parts.push('再生回数: ' + formatViewCount(v.viewCount));
    if (v.duration) parts.push('動画の長さ: ' + formatDuration(v.duration));
    parts.push('概要: ' + v.description);
    return parts.join('\n');
  }).join('\n\n');

  var prompt = '以下は青木仁志さんのYouTubeチャンネルの動画リストです。\n'
    + '本日のテーマ「' + themeLabel + '」に最も合致する動画を1本選んでください。\n\n'
    + '選定基準:\n'
    + '- テーマ「' + themeLabel + '」に内容が最も合致している\n'
    + '- 経営者・管理職・リーダーにとって実践的な示唆がある\n'
    + '- 具体的なノウハウ・事例・考え方が含まれている\n'
    + '- 再生回数が多く視聴者からの評価が高い動画を優先\n'
    + '- 極端に短い（2分未満）動画は避ける\n'
    + '- 30分を超える長尺動画は避ける（5〜30分が理想）\n\n'
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
      max_tokens: 800,
      stream: false,
      include_thoughts: false,
      messages: [
        { role: 'system', content: 'あなたはマネジメント・経営・人材育成の専門キュレーターです。指示されたJSON形式のみを返してください。前後の説明は一切不要です。' },
        { role: 'user', content: prompt }
      ]
    })
  });

  if (res.getResponseCode() !== 200) {
    Logger.log('KIE AI APIエラー: ' + res.getResponseCode() + ' ' + sanitizeErrorMessage(res.getContentText().slice(0, 300)));
    var fb = {}; for (var k in videos[0]) fb[k] = videos[0][k];
    fb.reason = '（AI選定APIがエラーのため先頭の動画を自動選出）';
    return [fb].slice(0, count);
  }

  var picks;
  try {
    var rawText = res.getContentText();
    var result = JSON.parse(rawText);
    var aiText = kieOpenAiExtractMessageText(result);
    if (!aiText && result.content && result.content[0] && result.content[0].text) {
      aiText = result.content[0].text;
    }
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
// Google Chat Incoming Webhook（cardsV2）
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
    var subParts = [pub];
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
          buttons: [{ text: 'YouTubeで開く', onClick: { openLink: { url: v.url } } }]
        }
      }
    ];
    var cardHeader = {
      title: escapeChatHtml(v.title),
      subtitle: subParts.join(' ｜ ')
    };
    if (v.thumbnail) cardHeader.imageUrl = v.thumbnail;
    return {
      cardId: 'ach-' + v.videoId + '-' + idx,
      card: { header: cardHeader, sections: [{ widgets: widgets }] }
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
// スプレッドシート操作（送信済みID管理）
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

function doGet(e) {
  return ContentService
    .createTextOutput('YouTube Achievement BOT (Google Chat) is running.')
    .setMimeType(ContentService.MimeType.TEXT);
}
