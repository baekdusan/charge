# Charge 수집기를 Windows 작업 스케줄러에 등록한다 (5분 간격).
# 실행: PowerShell에서 .\install.ps1  (실행 정책 오류 시: powershell -ExecutionPolicy Bypass -File install.ps1)
$ErrorActionPreference = "Stop"

$taskName = "ChargeConnect"
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Node가 없을 때 PowerShell 원문 에러 대신 사람이 읽을 수 있는 안내를 낸다
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    Write-Host "Node.js를 찾을 수 없습니다."
    Write-Host "https://nodejs.org 에서 LTS 버전을 설치한 뒤 다시 실행해주세요."
    exit 1
}
$node = $nodeCmd.Source

# 로그는 설정 폴더 옆에 둔다. 5분마다 쌓이므로 5MB를 넘으면 한 번 갈아준다.
$logDir = if ($env:CHARGE_HOME) { $env:CHARGE_HOME } else { Join-Path $env:USERPROFILE ".charge" }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "collector.log"
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 5MB)) { Move-Item -Force $log "$log.old" }

# 예전 이름(ChargeCollector)·예전 로그 위치의 잔재가 있으면 정리
Unregister-ScheduledTask -TaskName "ChargeCollector" -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:USERPROFILE "charge-connect.log")

# cmd /c 로 감싸 로그 리다이렉션 (작업 스케줄러는 자체 리다이렉션이 없음)
$arg = "/c `"`"$node`" `"$scriptDir\collect.js`" >> `"$log`" 2>&1`""
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $arg
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

# 기본값(LogonType Interactive)으로 등록하면 cmd.exe 콘솔 창이 5분마다 화면에 뜬다.
# S4U는 대화형 세션 없이 실행돼 창이 뜨지 않고, 로그오프 상태에서도 수집이 돈다.
# 권한이 모자라 S4U 등록이 막히는 환경이 있으므로 실패하면 기본 방식으로 되돌린다.
$registered = $false
try {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    $registered = $true
} catch {
    Write-Host "백그라운드 실행 등록 실패: $($_.Exception.Message)"
}
if (-not $registered) {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
}

Start-ScheduledTask -TaskName $taskName

if ((Get-ScheduledTask -TaskName $taskName).Principal.LogonType -eq "Interactive") {
    Write-Host "참고: 대화형 모드로 등록됐습니다 — 5분마다 콘솔 창이 잠깐 보일 수 있습니다."
}
Write-Host "등록 완료: $taskName (5분 간격). 로그: $log"
Write-Host "해제하려면: Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
