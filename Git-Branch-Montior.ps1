# Git Branch Monitor
# 監控 Git repository 分支更新並在發現新版本時執行指定動作

param(
    [string]$ConfigPath = "$PSScriptRoot\git-branch-monitor-config.json",
    [switch]$TestMode,
    [switch]$Debug,
    [switch]$AlwaysRunActions
)

# 設定除錯模式
$script:DebugMode = $Debug

# 記錄函式
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # 除了 DEBUG 訊息，其他都顯示在主控台
    if ($Level -ne "DEBUG" -or $script:DebugMode) {
        Write-Host $logMessage
    }
    
    # 寫入記錄檔（每天一個檔案）
    $logDir = "$PSScriptRoot\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logDate = Get-Date -Format "yyyy-MM-dd"
    $logPath = "$logDir\git-branch-monitor-$logDate.log"
    Add-Content -Path $logPath -Value $logMessage
    
    # 清理超過 3 天的舊 log 檔案
    $keepDays = 3
    $cutoffDate = (Get-Date).AddDays(-$keepDays)
    Get-ChildItem -Path $logDir -Filter "git-branch-monitor-*.log" | Where-Object {
        $_.LastWriteTime -lt $cutoffDate
    } | ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] 已刪除舊 log 檔案: $($_.Name)"
    }
}

# 取得 GitHub 分支最新 commit
function Get-GitHubLatestCommit {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Branch,
        [string]$Token
    )
    
    try {
        $uri = "https://api.github.com/repos/$Owner/$Repo/branches/$Branch"
        $headers = @{
            "Accept" = "application/vnd.github.v3+json"
            "User-Agent" = "PowerShell-git-branch-monitor"
        }
        
        if ($Token) {
            $headers["Authorization"] = "token $Token"
        }
        
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        
        return @{
            Success = $true
            CommitSha = $response.commit.sha
            CommitDate = $response.commit.commit.author.date
            CommitMessage = $response.commit.commit.message
            CommitAuthor = $response.commit.commit.author.name
        }
    }
    catch {
        Write-Log "GitHub API 錯誤: $_" "ERROR"
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# 取得 Bitbucket 分支最新 commit
function Get-BitbucketLatestCommit {
    param(
        [string]$Workspace,
        [string]$Repo,
        [string]$Branch,
        [string]$Token
    )
    
    try {
        # Bitbucket API v2.0 endpoint
        $uri = "https://api.bitbucket.org/2.0/repositories/$Workspace/$Repo/refs/branches/$Branch"
        
        Write-Log "Bitbucket API URI: $uri" "DEBUG"
        
        $headers = @{
            "Accept" = "application/json"
        }
        
        if (-not $Token) {
            Write-Log "Bitbucket 需要 API Token，請在設定檔提供 token" "ERROR"
            return @{ Success = $false; Error = "Missing Bitbucket API token" }
        }

        Write-Log "使用 Bitbucket API Token 認證" "DEBUG"
        $headers["Authorization"] = "Bearer $Token"
        
        # 使用 -ErrorAction Stop 確保捕捉所有錯誤
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        
        return @{
            Success = $true
            CommitSha = $response.target.hash
            CommitDate = $response.target.date
            CommitMessage = $response.target.message
            CommitAuthor = $response.target.author.raw
        }
    }
    catch {
        $errorDetails = $_.Exception.Message
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Log "HTTP 狀態碼: $statusCode" "ERROR"
            
            # 嘗試讀取錯誤回應內容
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                $reader.Close()
                Write-Log "API 回應: $responseBody" "ERROR"
            }
            catch {
                Write-Log "無法讀取錯誤回應" "ERROR"
            }
        }
        
        Write-Log "Bitbucket API 錯誤: $errorDetails" "ERROR"
        
        # 提供常見問題的建議
        if ($errorDetails -match "401" -or $errorDetails -match "Unauthorized") {
            Write-Log "認證失敗可能原因:" "ERROR"
            Write-Log "  1. API Token 已過期或無效" "ERROR"
            Write-Log "  2. Token 權限不足 (需要 repositories:read)" "ERROR"
            Write-Log "  3. Repository 為私有且需要存取權限" "ERROR"
        }
        
        return @{ Success = $false; Error = $errorDetails }
    }
}

# 發送通知
function Send-Notification {
    param(
        [string]$NotificationUrl,
        [string]$Title,
        [string]$Message,
        [string]$Priority = "default",
        [string[]]$Tags = @()
    )
    
    if (-not $NotificationUrl) {
        return
    }
    
    try {
        Write-Log "發送通知: $Title"
        
        # ntfy.sh 支援在 Body 第一行為標題，使用分隔符號分開
        $fullMessage = $Title
        if ($Message) {
            $fullMessage += "`n`n" + $Message
        }
        
        $headers = @{
            "Priority" = $Priority
        }
        
        # 添加標籤
        if ($Tags.Count -gt 0) {
            $headers["Tags"] = ($Tags -join ",")
        }
        
        $Request = @{
            Method = "POST"
            Uri = $NotificationUrl
            Headers = $headers
            Body = $fullMessage
            ContentType = "text/plain; charset=utf-8"
        }
        
        Invoke-RestMethod @Request | Out-Null
        Write-Log "通知發送成功" "DEBUG"
    }
    catch {
        Write-Log "發送通知失敗: $_" "ERROR"
    }
}

# 執行自訂動作
function Invoke-CustomAction {
    param(
        [string]$ActionType,
        [string]$ActionCommand,
        [hashtable]$RepoInfo,
        [hashtable]$CommitInfo
    )
    
    Write-Log "執行動作: $ActionType"
    
    switch ($ActionType) {
        "command" {
            # 替換變數
            $command = $ActionCommand `
                -replace '\$\{REPO_NAME\}', $RepoInfo.Name `
                -replace '\$\{BRANCH\}', $RepoInfo.Branch `
                -replace '\$\{COMMIT_SHA\}', $CommitInfo.CommitSha `
                -replace '\$\{COMMIT_MESSAGE\}', $CommitInfo.CommitMessage `
                -replace '\$\{COMMIT_AUTHOR\}', $CommitInfo.CommitAuthor
            
            Write-Log "執行命令: $command"
            
            # 執行命令並捕捉輸出與錯誤
            try {
                $output = Invoke-Expression $command 2>&1
                
                # 檢查退出碼
                if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
                    Write-Log "命令執行失敗，退出碼: $LASTEXITCODE" "ERROR"
                    if ($output) {
                        Write-Log "命令輸出: $output" "ERROR"
                    }
                    throw "命令執行失敗，退出碼: $LASTEXITCODE"
                }
                
                # 記錄輸出
                if ($output) {
                    Write-Log "命令輸出: $output" "DEBUG"
                }
            }
            catch {
                Write-Log "命令執行時發生異常: $_" "ERROR"
                throw
            }
        }
        "webhook" {
            $body = @{
                repo = $RepoInfo.Name
                branch = $RepoInfo.Branch
                commitSha = $CommitInfo.CommitSha
                commitMessage = $CommitInfo.CommitMessage
                commitAuthor = $CommitInfo.CommitAuthor
                commitDate = $CommitInfo.CommitDate
            } | ConvertTo-Json
            
            Write-Log "發送 Webhook: $ActionCommand"
            Write-Log "Webhook 內容: $body" "DEBUG"
            
            # 發送 Webhook 並處理錯誤
            try {
                $response = Invoke-RestMethod -Uri $ActionCommand -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
                
                Write-Log "Webhook 發送成功" "DEBUG"
                if ($response) {
                    Write-Log "Webhook 回應: $($response | ConvertTo-Json -Compress)" "DEBUG"
                }
            }
            catch {
                $errorMsg = $_.Exception.Message
                
                # 如果有 HTTP 回應，記錄詳細資訊
                if ($_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Log "Webhook HTTP 狀態碼: $statusCode" "ERROR"
                    
                    # 嘗試讀取錯誤回應內容
                    try {
                        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                        $responseBody = $reader.ReadToEnd()
                        $reader.Close()
                        Write-Log "Webhook 錯誤回應: $responseBody" "ERROR"
                        $errorMsg = "HTTP $statusCode - $responseBody"
                    }
                    catch {
                        $errorMsg = "HTTP $statusCode - $errorMsg"
                    }
                }
                
                Write-Log "Webhook 發送失敗: $errorMsg" "ERROR"
                throw "Webhook 發送失敗: $errorMsg"
            }
        }
        default {
            Write-Log "未知的動作類型: $ActionType" "ERROR"
            throw "未知的動作類型: $ActionType"
        }
    }
}

# 主要監控邏輯
function Start-GitMonitor {
    param([string]$ConfigPath)
    
    # 讀取設定檔
    if (-not (Test-Path $ConfigPath)) {
        Write-Log "設定檔不存在: $ConfigPath" "ERROR"
        return
    }
    
    Write-Log "讀取設定檔: $ConfigPath"
    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    
    # 狀態檔案路徑
    $statePath = "$PSScriptRoot\git-branch-monitor-state.json"
    
    # 讀取上次狀態
    $state = @{}
    if (Test-Path $statePath) {
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json -AsHashtable
    }
    
    # 監控每個 repository
    foreach ($repo in $config.repositories) {
        $repoKey = "$($repo.provider):$($repo.name):$($repo.branch)"
        Write-Log "檢查 $repoKey"
        
        # 處理本地 Git repository
        if ($repo.localPath) {
            $localPath = $repo.localPath
            Write-Log "本地路徑: $localPath"
            
            # 檢查本地路徑是否已有 git repository
            if (-not (Test-Path "$localPath\.git")) {
                Write-Log "本地 repository 不存在，開始 clone..." "INFO"
                
                # 建構 clone URL
                $cloneUrl = ""
                switch ($repo.provider) {
                    "github" {
                        if ($repo.token) {
                            $cloneUrl = "https://$($repo.token)@github.com/$($repo.owner)/$($repo.name).git"
                        } else {
                            $cloneUrl = "https://github.com/$($repo.owner)/$($repo.name).git"
                        }
                    }
                    "bitbucket" {
                        if ($repo.token) {
                            $cloneUrl = "https://x-token-auth:$($repo.token)@bitbucket.org/$($repo.workspace)/$($repo.name).git"
                        } else {
                            $cloneUrl = "https://bitbucket.org/$($repo.workspace)/$($repo.name).git"
                        }
                    }
                }
                
                if ($cloneUrl) {
                    try {
                        # 確保父目錄存在
                        $parentPath = Split-Path -Parent $localPath
                        if (-not (Test-Path $parentPath)) {
                            New-Item -ItemType Directory -Path $parentPath -Force | Out-Null
                        }
                        
                        Write-Log "執行: git clone $cloneUrl $localPath"
                        $cloneOutput = git clone $cloneUrl $localPath 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "Clone 成功" "INFO"
                        } else {
                            Write-Log "Clone 失敗: $cloneOutput" "ERROR"
                            continue
                        }
                    }
                    catch {
                        Write-Log "Clone 發生錯誤: $_" "ERROR"
                        continue
                    }
                }
            }
            
            # 切換到本地路徑並 switch 分支
            if (Test-Path "$localPath\.git") {
                try {
                    Push-Location $localPath
                    
                    # 取得當前分支
                    $currentBranch = git branch --show-current 2>&1
                    Write-Log "當前分支: $currentBranch"
                    
                    # Switch 到監控的分支
                    if ($currentBranch -ne $repo.branch) {
                        Write-Log "切換到分支: $($repo.branch)"
                        $switchOutput = git switch $repo.branch 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            Write-Log "切換分支失敗，嘗試建立新分支: $switchOutput" "WARN"
                            $switchOutput = git switch -c $repo.branch "origin/$($repo.branch)" 2>&1
                            if ($LASTEXITCODE -ne 0) {
                                Write-Log "建立分支失敗: $switchOutput" "ERROR"
                            }
                        }
                    }
                }
                catch {
                    Write-Log "Git 操作發生錯誤: $_" "ERROR"
                    Pop-Location
                    continue
                }
                finally {
                    Pop-Location
                }
            }
        }
        
        # 取得最新 commit
        $result = $null
        switch ($repo.provider) {
            "github" {
                $result = Get-GitHubLatestCommit -Owner $repo.owner -Repo $repo.name -Branch $repo.branch -Token $repo.token
            }
            "bitbucket" {
                $result = Get-BitbucketLatestCommit -Workspace $repo.workspace -Repo $repo.name -Branch $repo.branch -Token $repo.token
            }
            default {
                Write-Log "未知的 provider: $($repo.provider)" "ERROR"
                continue
            }
        }
        
        if (-not $result.Success) {
            Write-Log "取得 commit 資訊失敗: $($result.Error)" "ERROR"
            continue
        }
        
        # 讀取上次狀態（支援舊格式和新格式）
        $lastState = $state[$repoKey]
        $lastCommitSha = $null
        $failureCount = 0
        $lastError = $null
        $lastFailureTime = $null

        if ($lastState) {
            if ($lastState -is [string]) {
                # 舊格式：直接是 commit SHA
                $lastCommitSha = $lastState
                Write-Log "偵測到舊格式狀態，將自動轉換為新格式" "DEBUG"
            } else {
                # 新格式：包含詳細資訊的物件
                $lastCommitSha = $lastState.commitSha
                $failureCount = if ($lastState.failureCount) { $lastState.failureCount } else { 0 }
                $lastError = $lastState.lastError
                $lastFailureTime = $lastState.lastFailureTime
            }
        }

        $currentCommitSha = $result.CommitSha

        # 檢查失敗次數是否超過限制
        if ($failureCount -ge 3) {
            # 如果有新的 commit，重置失敗次數並給予新機會
            if ($lastCommitSha -ne $currentCommitSha) {
                Write-Log "偵測到新的 commit ($($currentCommitSha.Substring(0,7)))，與上次失敗的版本不同，重置失敗次數並重新嘗試" "INFO"
                $failureCount = 0
                $lastError = $null
                $lastFailureTime = $null
            } else {
                Write-Log "此 repository 已連續失敗 $failureCount 次，且無新版本，跳過執行動作" "WARN"
                if ($lastError) {
                    Write-Log "最後錯誤: $lastError" "WARN"
                }
                if ($lastFailureTime) {
                    Write-Log "最後失敗時間: $lastFailureTime" "WARN"
                }
                continue
            }
        }
        
        # 檢查是否有新版本，首次監控也執行動作
        $shouldRunAction = $false

        if (-not $lastCommitSha) {
            Write-Log "首次監控此 repository,記錄並執行動作: $currentCommitSha" "INFO"
            $shouldRunAction = $true
        }
        elseif ($lastCommitSha -ne $currentCommitSha) {
            Write-Log "發現新版本!" "INFO"
            Write-Log "  舊版本: $lastCommitSha" "INFO"
            Write-Log "  新版本: $currentCommitSha" "INFO"
            Write-Log "  Commit 訊息: $($result.CommitMessage)" "INFO"
            Write-Log "  作者: $($result.CommitAuthor)" "INFO"
            $shouldRunAction = $true
        }
        elseif ($AlwaysRunActions) {
            Write-Log "無新版本，但已啟用 AlwaysRunActions，仍執行動作" "INFO"
            $shouldRunAction = $true
        }
        else {
            Write-Log "無新版本 (當前: $currentCommitSha)" "INFO"
        }

        if ($shouldRunAction) {
            # 發送準備更新通知（如果有設定 notificationUrl）
            if ($repo.notificationUrl) {
                $title = "🔄 $($repo.name) 發現新版本，準備更新"
                $message = "Repository: $($repo.name)`nBranch: $($repo.branch)`nNew Commit: $($result.CommitSha.Substring(0,7))`nAuthor: $($result.CommitAuthor)`nMessage: $($result.CommitMessage)"
                Send-Notification -NotificationUrl $repo.notificationUrl -Title $title -Message $message -Priority "default" -Tags @("arrows_counterclockwise")
            }
            
            # 如果有新版本且設定了本地路徑，執行 git pull
            $pullSuccess = $true
            $pullError = $null
            if ($repo.localPath -and (Test-Path "$($repo.localPath)\.git")) {
                try {
                    Write-Log "執行 git pull 更新到最新版本"
                    Push-Location $repo.localPath
                    
                    # 如果有 token，更新 remote URL 以包含認證資訊
                    if ($repo.token) {
                        $remoteUrl = ""
                        switch ($repo.provider) {
                            "github" {
                                $remoteUrl = "https://$($repo.token)@github.com/$($repo.owner)/$($repo.name).git"
                            }
                            "bitbucket" {
                                $remoteUrl = "https://x-token-auth:$($repo.token)@bitbucket.org/$($repo.workspace)/$($repo.name).git"
                            }
                        }
                        
                        if ($remoteUrl) {
                            Write-Log "更新 remote URL 以包含認證資訊" "DEBUG"
                            git remote set-url origin $remoteUrl 2>&1 | Out-Null
                        }
                    }
                    
                    $pullOutput = git pull 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Git pull 成功: $pullOutput" "INFO"
                    } else {
                        $pullSuccess = $false
                        $pullError = "Git pull 失敗: $pullOutput"
                        Write-Log $pullError "ERROR"
                    }
                    Pop-Location
                }
                catch {
                    $pullSuccess = $false
                    $pullError = "Git pull 發生錯誤: $_"
                    Write-Log $pullError "ERROR"
                    Pop-Location
                }
            }
            
            # 如果 git pull 失敗，記錄失敗狀態並發送通知
            if (-not $pullSuccess) {
                $failureCount++
                $state[$repoKey] = @{
                    commitSha = $lastCommitSha
                    failureCount = $failureCount
                    lastError = $pullError
                    lastFailureTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
                
                # 發送失敗通知
                if ($repo.notificationUrl) {
                    $title = "❌ $($repo.name) Git Pull 失敗 ($failureCount/3)"
                    $message = "Repository: $($repo.name)`nBranch: $($repo.branch)`nCommit: $($result.CommitSha.Substring(0,7))`n失敗次數: $failureCount / 3`n`n錯誤:`n$pullError"
                    Send-Notification -NotificationUrl $repo.notificationUrl -Title $title -Message $message -Priority "high" -Tags @("x")
                }
                
                Write-Log "Git pull 失敗，失敗次數: $failureCount / 3" "WARN"
                if ($failureCount -ge 3) {
                    Write-Log "已達到最大失敗次數，下次檢查將跳過此 repository" "ERROR"
                }
                continue
            }
            
            # 執行自訂動作
            $actionSuccess = $true
            $actionErrors = @()
            if ($repo.actions -and -not $TestMode) {
                foreach ($action in $repo.actions) {
                    try {
                        Invoke-CustomAction -ActionType $action.type -ActionCommand $action.command `
                            -RepoInfo @{
                                Name = $repo.name
                                Branch = $repo.branch
                                Provider = $repo.provider
                            } `
                            -CommitInfo $result
                    }
                    catch {
                        $actionSuccess = $false
                        $errorMsg = $_.Exception.Message
                        $actionErrors += $errorMsg
                        Write-Log "執行動作時發生錯誤: $errorMsg" "ERROR"
                    }
                }
            }
            
            # 發送通知（如果有設定 notificationUrl）
            if ($repo.notificationUrl) {
                if ($actionSuccess) {
                    $title = "✅ $($repo.name) 更新成功"
                    $message = "Repository: $($repo.name)`nBranch: $($repo.branch)`nCommit: $($result.CommitSha.Substring(0,7))`nAuthor: $($result.CommitAuthor)`nMessage: $($result.CommitMessage)"
                    Send-Notification -NotificationUrl $repo.notificationUrl -Title $title -Message $message -Priority "default" -Tags @("white_check_mark")
                } else {
                    $newFailureCount = $failureCount + 1
                    $title = "❌ $($repo.name) 更新失敗 ($newFailureCount/3)"
                    $message = "Repository: $($repo.name)`nBranch: $($repo.branch)`nCommit: $($result.CommitSha.Substring(0,7))`n失敗次數: $newFailureCount / 3`n`n錯誤:`n$($actionErrors -join "`n")"
                    Send-Notification -NotificationUrl $repo.notificationUrl -Title $title -Message $message -Priority "high" -Tags @("x")
                }
            }
            
            # 根據執行結果更新狀態
            if ($actionSuccess) {
                # 成功：更新狀態並清除失敗記錄
                $state[$repoKey] = @{
                    commitSha = $currentCommitSha
                    failureCount = 0
                    lastError = $null
                    lastFailureTime = $null
                }
                Write-Log "狀態已更新: $repoKey -> $currentCommitSha，失敗記錄已清除" "DEBUG"
            } else {
                # 失敗：增加失敗次數並記錄錯誤，但不更新 commitSha
                $failureCount++
                $state[$repoKey] = @{
                    commitSha = $lastCommitSha
                    failureCount = $failureCount
                    lastError = ($actionErrors -join "; ")
                    lastFailureTime = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
                Write-Log "動作執行失敗，失敗次數: $failureCount / 3" "WARN"
                if ($failureCount -ge 3) {
                    Write-Log "已達到最大失敗次數，下次檢查將跳過此 repository" "ERROR"
                }
            }
        }
        else {
            # 無新版本時也更新狀態（確保首次監控後的狀態正確），並保持失敗計數為 0
            $state[$repoKey] = @{
                commitSha = $currentCommitSha
                failureCount = 0
                lastError = $null
                lastFailureTime = $null
            }
        }
    }
    
    # 儲存狀態
    $state | ConvertTo-Json | Set-Content -Path $statePath
    Write-Log "狀態已儲存"
}

# 執行監控
try {
    Write-Log "========== Git Branch Monitor 開始執行 =========="
    if ($TestMode) {
        Write-Log "測試模式: 不會執行實際動作" "INFO"
    }
    Start-GitMonitor -ConfigPath $ConfigPath
    Write-Log "========== Git Branch Monitor 執行完成 =========="
}
catch {
    Write-Log "執行過程發生錯誤: $_" "ERROR"
    exit 1
}
