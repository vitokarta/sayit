# SayIt 開發指令速查

## 環境啟動

### 後端 venv（每次開新 terminal 都要）
```bash
cd ~/temp/test_for_gemma/sayit/backend
source venv/bin/activate
```

---

## 本地測試（HTML 播放器）

### 跑 pipeline + 開啟播放器
```bash
cd ~/temp/test_for_gemma/sayit/backend
source venv/bin/activate
python pipeline.py
# 輸入 YouTube URL 或直接 Enter 用預設影片
# 完成後自動開瀏覽器：http://localhost:8080/player.html
```

**說明：**
- 有快取時跳過已完成步驟（Whisper / Gemma / TTS / 摘要各自獨立快取）
- 練習模式需用 Chrome（Web Speech API）
- 按 Ctrl+C 關閉 server

### 清除快取（強制重新處理）
```bash
rm -rf ~/temp/test_for_gemma/sayit/backend/tmp/sayit/<video_id>/
```

---

## 本地 FastAPI 後端

```bash
cd ~/temp/test_for_gemma/sayit/backend
source venv/bin/activate
python -m uvicorn main:app --reload
# 後端跑在 http://localhost:8000
```

### 測試 API
```bash
# 處理影片
curl -X POST http://localhost:8000/process \
  -H "Content-Type: application/json" \
  -d '{"url": "https://www.youtube.com/watch?v=ZQ1JPYpIOwg"}'

# 查詢進度
curl http://localhost:8000/status/<job_id>

# 取得影片資料
curl http://localhost:8000/video/ZQ1JPYpIOwg
```

---

## Flutter Android App

### 前置：啟動 Android 模擬器
1. 開 **Android Studio**
2. **More Actions → Virtual Device Manager**
3. 點 ▶ 啟動模擬器（等到 Android 桌面出現，約 1-2 分鐘）

### 跑 Flutter app（模擬器需先啟動）
```bash
cd ~/temp/test_for_gemma/sayit/flutter/sayit_app
flutter run
```

**Hot reload 快捷鍵（terminal 內）：**
- `r` → Hot reload（程式碼改動立即生效）
- `R` → Hot restart（完整重啟）
- `q` → 退出

### 安裝套件（新增套件後）
```bash
cd ~/temp/test_for_gemma/sayit/flutter/sayit_app
flutter pub get
```

---

## 線上服務

| 項目 | 說明 |
|------|------|
| 後端 URL | `https://sayit-x056.onrender.com` |
| 部署方式 | push 到 GitHub `vitokarta/sayit` 自動觸發 |
| 休眠 | 15 分鐘無流量會睡著，第一個請求等約 1 分鐘 |

### 測試線上 API
```bash
curl https://sayit-x056.onrender.com/video/ZQ1JPYpIOwg
```

---

## Git 流程

```bash
# 查看狀態
git status

# commit（在 sayit/ 根目錄執行）
git add <檔案>
git commit -m "說明"
git push origin main   # 自動觸發 Render 重新部署
```
