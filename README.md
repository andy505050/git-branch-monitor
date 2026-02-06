# Git Branch Monitor - Git 分支監控工具

自動監控 GitHub 和 Bitbucket repository 的分支更新狀態，當檢測到新版本時執行自訂動作。

## 功能特色

- ✅ 支援 GitHub 和 Bitbucket
- ✅ 監控多個 repository 和分支
- ✅ 檢測到新 commit 時執行自訂動作
- ✅ 首次監控時自動執行動作（建立基準）
- ✅ 支援三種動作類型：命令、腳本、Webhook
- ✅ 支援 ntfy.sh 通知（成功/失敗皆會通知）
- ✅ 智慧錯誤處理：失敗最多記錄 3 次後自動跳過，成功時清除錯誤記錄
- ✅ 記錄執行歷史
- ✅ 狀態持久化儲存
- ✅ Debug 模式協助疑難排解

## 檔案說明

- `Git-Branch-Montior.ps1` - 主要監控腳本
- `git-branch-monitor-config.json` - 設定檔（定義要監控的 repositories）
- `git-branch-monitor-config.example.json` - 範例設定檔（可複製此檔案開始設定）
- `git-branch-monitor-state.json` - 狀態檔（自動產生，記錄最後檢查的 commit、失敗次數及錯誤資訊）
- `logs/` - 記錄檔資料夾（自動產生，每天一個檔案，保留 3 天）

## 快速開始

### 1. 設定監控的 Repositories

首次使用時，可以複製範例設定檔：

```powershell
Copy-Item git-branch-monitor-config.example.json git-branch-monitor-config.json
```

然後編輯 `git-branch-monitor-config.json`，填入你要監控的 repositories 和 API token：

```json
{
  "repositories": [
    {
      "provider": "github",
      "owner": "microsoft",
      "name": "vscode",
      "branch": "main",
      "token": "ghp_your_personal_access_token",
      "actions": [
        {
          "type": "command",
          "command": "Write-Host '新版本: ${COMMIT_SHA}'"
        }
      ]
    }
  ]
}
```

### 2. 取得 API 認證資訊

#### GitHub Personal Access Token

1. 前往 GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token
3. 選擇權限：`repo` (存取私有 repository) 或 `public_repo` (僅公開 repository)
4. 複製 token 並填入設定檔

#### Bitbucket Personal Access Token

1. 前往 Bitbucket → Personal settings → Access management → Personal access tokens
2. 建立 Token，選擇權限：`Repositories: Read`
3. 複製 token 並填入設定檔的 `token`

### 3. 測試執行

```powershell
# 測試模式（不會執行實際動作）
.\Git-Branch-Montior.ps1 -TestMode

# 正常執行
.\Git-Branch-Montior.ps1

# 使用自訂設定檔
.\Git-Branch-Montior.ps1 -ConfigPath "C:\path\to\config.json"

# Debug 模式（顯示詳細除錯訊息）
.\Git-Branch-Montior.ps1 -Debug

# 強制執行動作（即使沒有新版本）
.\Git-Branch-Montior.ps1 -AlwaysRunActions
```

#### 參數說明

- `-TestMode` - 測試模式，檢查 repository 狀態但不執行動作
- `-ConfigPath` - 指定自訂設定檔路徑（預設：當前目錄下的 `git-branch-monitor-config.json`）
- `-Debug` - 開啟 Debug 模式，顯示詳細的 API 請求和回應資訊
- `-AlwaysRunActions` - 強制執行所有動作，即使沒有檢測到新版本

### 4. 設定定期執行

#### 方法 A：使用 Windows 工作排程器

#### 方法 B：使用迴圈持續監控

```powershell
# 每 10 分鐘執行一次，持續監控
while ($true) {
    .\Git-Branch-Montior.ps1
    Start-Sleep -Seconds 600
}
```

## 監控行為說明

### 首次監控

當腳本首次監控某個 repository 和分支時（狀態檔中沒有記錄）：

1. 記錄當前的 commit SHA
2. **自動執行所有設定的動作**
3. 這樣可以確保監控系統正常運作並建立基準

### 後續監控

每次執行時：

1. 取得最新的 commit SHA
2. 與上次記錄的 commit SHA 比對
3. 如果發現新版本（SHA 不同），執行所有設定的動作
4. 更新狀態檔記錄新的 commit SHA

### 強制執行動作

使用 `-AlwaysRunActions` 參數可以強制執行動作，即使沒有新版本：

```powershell
.\Git-Branch-Montior.ps1 -AlwaysRunActions
```

這在測試動作設定或確保定期執行某些任務時很有用。

## 錯誤處理機制

當動作執行失敗時，腳本會自動記錄失敗資訊並實施智慧重試策略：

### 失敗處理流程

1. **第一次失敗**
   - 記錄錯誤訊息和失敗時間
   - 失敗次數 +1（共 1/3）
   - **不更新** commit SHA（下次仍會嘗試部署相同版本）
   - 發送失敗通知（如有設定）

2. **第二、三次失敗**
   - 繼續記錄錯誤資訊
   - 失敗次數累加（2/3、3/3）
   - 仍然不更新 commit SHA
   - 發送失敗通知顯示累計次數

3. **達到最大失敗次數（3 次）**
   - 如果仍是**相同的 commit**：
     - 自動跳過該 repository 的動作執行
     - 在日誌中記錄警告訊息
     - 顯示最後的錯誤訊息和失敗時間
   - 如果偵測到**新的 commit**：
     - 🔄 **自動重置失敗次數為 0**
     - 清除錯誤記錄
     - 像處理新版本一樣重新嘗試執行動作
     - 給予每個新版本獨立的重試機會

4. **成功執行**
   - 更新 commit SHA 到最新版本
   - **清除所有失敗記錄**（重置為 0/3）
   - 發送成功通知

### 狀態檔案結構

新版本的狀態檔 `git-branch-monitor-state.json` 包含：

```json
{
  "github:my-app:main": {
    "commitSha": "a1b2c3d4e5f6...",
    "failureCount": 0,
    "lastError": null,
    "lastFailureTime": null
  },
  "bitbucket:api-service:develop": {
    "commitSha": "9z8y7x6w5v4u...",
    "failureCount": 2,
    "lastError": "執行動作時發生錯誤: 找不到檔案 'deploy.ps1'",
    "lastFailureTime": "2026-02-06 14:30:45"
  }
}
```

**欄位說明：**

- `commitSha` - 最後成功處理的 commit SHA
- `failureCount` - 連續失敗次數（0-3）
- `lastError` - 最後一次的錯誤訊息
- `lastFailureTime` - 最後失敗的時間

**向後相容性：** 舊版本的狀態檔（僅包含 commit SHA 字串）會自動轉換為新格式，無需手動處理。

### 智慧重試機制

系統會自動判斷是否給予新的執行機會：

- **相同版本連續失敗**：某個 commit 失敗 3 次後，不再重試該版本
- **新版本自動重試**：當開發者推送新的 commit 時，自動重置失敗計數
- **獨立計數**：每個新 commit 都有獨立的 3 次重試機會

**範例情境：**

```
commit A → 失敗 3 次 → 停止重試 commit A
commit B 推送 → 自動重置為 0/3 → 開始嘗試 commit B
commit B → 成功 → 清除所有失敗記錄 ✅
```

### 手動重置失敗記錄

在某些情況下，你可能需要手動重置（例如修復了部署環境問題，但 repository 沒有新 commit）：

```powershell
# 方法 1：刪除整個狀態檔（所有 repositories 都會視為首次監控）
Remove-Item .\git-branch-monitor-state.json

# 方法 2：手動編輯狀態檔，將特定 repository 的 failureCount 改為 0
# 或直接刪除該 repository 的記錄
```

## 設定檔格式

### Repository 設定

#### GitHub Repository

```json
{
  "provider": "github",
  "owner": "repository-owner",
  "name": "repository-name",
  "branch": "main",
  "token": "ghp_xxxxx",
  "actions": [...]
}
```

#### Bitbucket Repository

```json
{
  "provider": "bitbucket",
  "workspace": "workspace-name",
  "name": "repository-name",
  "branch": "develop",
  "token": "bitbucket-personal-access-token",
  "actions": [...]
}
```

### 通知設定（可選）

可以為每個 repository 設定 `notificationUrl`，當動作執行成功或失敗時，會自動發送通知。

**注意**：目前僅支援不需要認證的通知服務（例如 ntfy.sh）。

#### 使用 ntfy.sh

ntfy.sh 是一個完全免費的通知服務，不需註冊和認證即可使用。

```json
{
  "provider": "github",
  "owner": "your-org",
  "name": "your-repo",
  "branch": "main",
  "token": "ghp_xxxxx",
  "notificationUrl": "https://ntfy.sh/your-unique-topic",
  "actions": [...]
}
```

**設定步驟：**

1. 選擇一個獨特的 topic 名稱（例如：`myproject-ci-alerts`）
2. 在手機上安裝 ntfy app（[Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) / [iOS](https://apps.apple.com/app/ntfy/id1625396347)）
3. 在 app 中訂閱你的 topic
4. 完成！現在會收到推播通知

**通知內容：**

- ✅ **成功**：顯示 repository、分支、commit 資訊
- ❌ **失敗**：顯示錯誤訊息，優先級較高

### 動作類型

#### 1. Command - 執行命令或腳本

```json
{
  "type": "command",
  "command": "Write-Host '檢測到更新: ${REPO_NAME} - ${COMMIT_SHA}'"
}
```

可用變數：

- `${REPO_NAME}` - Repository 名稱
- `${BRANCH}` - 分支名稱
- `${COMMIT_SHA}` - Commit SHA
- `${COMMIT_MESSAGE}` - Commit 訊息
- `${COMMIT_AUTHOR}` - Commit 作者

執行外部腳本範例：

```json
{
  "type": "command",
  "command": "& 'C:\\Scripts\\deploy.ps1' -RepoName '${REPO_NAME}' -Branch '${BRANCH}' -CommitSha '${COMMIT_SHA}'"
}
```

#### 2. Webhook - 發送 HTTP POST 請求

```json
{
  "type": "webhook",
  "command": "https://your-webhook-url.com/notify"
}
```

POST Body 格式：

```json
{
  "repo": "repository-name",
  "branch": "main",
  "commitSha": "abc123...",
  "commitMessage": "Update README",
  "commitAuthor": "John Doe",
  "commitDate": "2025-12-16T10:00:00Z"
}
```

## 使用範例

### 範例 1：監控並發送通知

```json
{
  "repositories": [
    {
      "provider": "github",
      "owner": "your-org",
      "name": "production-app",
      "branch": "main",
      "token": "ghp_xxxxx",
      "actions": [
        {
          "type": "command",
          "command": "msg * '偵測到 production-app 更新! Commit: ${COMMIT_SHA}'"
        }
      ]
    }
  ]
}
```

### 範例 2：自動部署

```json
{
  "repositories": [
    {
      "provider": "bitbucket",
      "workspace": "myteam",
      "name": "api-service",
      "branch": "develop",
      "token": "bitbucket-personal-access-token",
      "actions": [
        {
          "type": "command",
          "command": "& 'C:\\Deploy\\deploy-api.ps1' -RepoName '${REPO_NAME}' -Branch '${BRANCH}' -CommitSha '${COMMIT_SHA}'"
        },
        {
          "type": "webhook",
          "command": "https://slack.com/api/webhook/xxxxx"
        }
      ]
    }
  ]
}
```

### 範例 3：監控多個分支

```json
{
  "repositories": [
    {
      "provider": "github",
      "owner": "myorg",
      "name": "myapp",
      "branch": "main",
      "token": "ghp_xxxxx",
      "actions": [
        {
          "type": "command",
          "command": "Write-Host 'Production 更新'"
        }
      ]
    },
    {
      "provider": "github",
      "owner": "myorg",
      "name": "myapp",
      "branch": "develop",
      "token": "ghp_xxxxx",
      "actions": [
        {
          "type": "command",
          "command": "Write-Host 'Development 更新'"
        }
      ]
    }
  ]
}
```

## 進階功能

### 自訂部署腳本範例

建立 `deploy.ps1`：

```powershell
param(
    [string]$RepoName,
    [string]$Branch,
    [string]$CommitSha
)

Write-Host "開始部署 $RepoName ($Branch) - Commit: $CommitSha"

# 1. Pull 最新程式碼
cd "C:\Projects\$RepoName"
git pull origin $Branch

# 2. 執行建構
npm run build

# 3. 重啟服務
Restart-Service -Name "MyAppService"

Write-Host "部署完成!"
```

### 整合 Slack 通知

```json
{
  "type": "webhook",
  "command": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
}
```

Webhook 會自動發送包含 commit 資訊的 JSON payload。

### 整合 Microsoft Teams

建立 PowerShell 命令動作：

```json
{
  "type": "command",
  "command": "$body = @{ text = 'Repository ${REPO_NAME} 有新更新! Commit: ${COMMIT_SHA}' } | ConvertTo-Json; Invoke-RestMethod -Uri 'YOUR_TEAMS_WEBHOOK_URL' -Method Post -Body $body -ContentType 'application/json'"
}
```

## 疑難排解

### 問題：API 請求失敗

#### GitHub API 錯誤

- 確認 Personal Access Token 格式正確（以 `ghp_` 開頭）
- 檢查 token 權限：
  - 公開 repository：需要 `public_repo` 權限
  - 私有 repository：需要完整 `repo` 權限
- 確認 repository owner 和名稱拼寫正確
- 檢查網路連線和防火牆設定

#### Bitbucket API 錯誤

使用 `-Debug` 參數查看詳細錯誤訊息：

```powershell
.\Git-Branch-Montior.ps1 -Debug
```

常見錯誤：

**401 Unauthorized（認證失敗）**

- Token 已過期或無效，需重新產生
- Token 權限不足，確認已授予 `Repositories: Read` 權限
- Repository 為私有且帳號無存取權限

**404 Not Found**

- Workspace 名稱錯誤（不是 username）
- Repository 名稱拼寫錯誤
- 分支名稱不存在

**403 Forbidden**

- 超過 API 速率限制，請稍後再試
- Token 無該 repository 的存取權限

### 問題：動作未執行

- 首次監控會自動執行動作並建立基準，這是正常行為
- 使用 `-TestMode` 參數測試而不執行實際動作
- 檢查 `git-branch-monitor.log` 記錄檔查看詳細資訊
- 確認腳本路徑使用絕對路徑（避免相對路徑問題）
- 使用 `-AlwaysRunActions` 測試動作是否能正常執行

### 問題：工作排程器未執行

- 確認執行原則：`Set-ExecutionPolicy RemoteSigned`
- 檢查 XML 檔案中的路徑是否正確
- 在工作排程器中查看最後執行結果
- 確認工作排程器的執行身分有足夠權限

### Debug 技巧

1. **檢視詳細日誌**

   ```powershell
   # 查看今天的日誌
   Get-Content .\logs\git-branch-monitor-$(Get-Date -Format 'yyyy-MM-dd').log -Tail 50

   # 或查看最新的日誌檔案
   Get-Content (Get-ChildItem .\logs\*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Tail 50
   ```

2. **測試 API 連線（使用 Debug 模式）**

   ```powershell
   .\Git-Branch-Montior.ps1 -Debug -TestMode
   ```

3. **測試動作執行**

   ```powershell
   .\Git-Branch-Montior.ps1 -AlwaysRunActions -TestMode
   ```

4. **清除狀態檔案重新開始**
   ```powershell
   Remove-Item .\git-branch-monitor-state.json
   .\Git-Branch-Montior.ps1
   ```

## 安全性建議

1. **不要** 將包含 token/password 的設定檔提交到版本控制
2. 使用 `.gitignore` 排除 `git-branch-monitor-config.json`
3. 定期更新 API tokens
4. 對 GitHub 使用有限權限的 token
5. 考慮使用環境變數儲存敏感資訊

## 記錄檔位置

- 執行記錄：`logs/git-branch-monitor-YYYY-MM-DD.log`（每天一個檔案，自動保留 3 天）
- 狀態檔案：`git-branch-monitor-state.json`

## 授權

MIT License

## 版本歷史

- v1.1 (2026-02-06) - 錯誤處理改進
  - 新增智慧失敗處理機制
  - 失敗最多記錄 3 次後自動跳過
  - 成功時自動清除錯誤記錄 - **智慧重試**：偵測到新 commit 時自動重置失敗次數
  - 每個新版本都有獨立的重試機會 - 改進狀態檔結構（包含失敗次數、錯誤訊息、失敗時間）
  - 向後相容舊版狀態檔格式
  - 通知訊息顯示失敗次數進度

- v1.0 (2025-12-16) - 初始版本
  - 支援 GitHub 和 Bitbucket
  - 三種動作類型
  - 狀態持久化
