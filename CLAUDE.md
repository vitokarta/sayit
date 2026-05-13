# SayIt — Claude 開發指引

## 專案概述

SayIt 是個人英語聽說練習 app，把中文 YouTube 影片轉成英語學習內容。

**核心流程：**
YouTube URL → Groq Whisper（中文 STT）→ Gemma 3（校正+分段+翻譯）→ Google TTS（英文音訊+時間戳）→ 儲存 Supabase → Flutter app 播放

## 專案結構

```
sayit/
├── backend/
│   ├── pipeline.py       # 完整 pipeline
│   ├── main.py           # FastAPI：POST /process, GET /status/{job_id}, GET /video/{video_id}
│   ├── requirements.txt
│   ├── Dockerfile        # Render 部署用
│   ├── Procfile          # Railway 備用
│   └── nixpacks.toml     # Railway 備用
├── flutter/
│   └── sayit_app/
│       └── lib/
│           ├── main.dart         # 首頁（輸入 YouTube URL）
│           ├── models.dart       # Video / Segment / Sentence 資料結構
│           └── player_screen.dart # 聆聽模式（逐句高亮播放）
├── render.yaml           # Render 部署設定
└── CLAUDE.md
```

## 本機啟動後端

```bash
cd backend
python -m uvicorn main:app --reload
```

環境變數放在 `backend/.env`（不進 git）：
- `GROQ_API_KEY`
- `GEMINI_API_KEY`
- `GOOGLE_TTS_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `SUPADATA_API_KEY` — 字幕擷取（supadata.ai，免費 100 次/月）
- `YOUTUBE_COOKIES_B64` — yt-dlp fallback 用（選用）

## 部署

- **後端**：Render（Docker），`https://sayit-x056.onrender.com`，從 GitHub `vitokarta/sayit` 自動部署
- **資料**：Supabase，bucket `sayit-audio`，table `videos`

## Supabase 資料結構

`videos` table：
```
id      TEXT  — YouTube video ID
title   TEXT
data    JSONB — { segments: [ { audio_url, sentences: [ { zh, en, tts_start } ] } ] }
```

## Flutter app

- 目標平台：Android
- 套件：`http`（API 呼叫）、`just_audio`（音訊播放）
- 聆聽模式：逐句高亮，點句子跳時間點，segment 播完自動接下一段

## 開發狀態

- [x] Backend pipeline
- [x] FastAPI 後端
- [x] Render 部署
- [x] Flutter 聆聽模式（開發中）
- [ ] Flutter 練習模式（口說批改）
