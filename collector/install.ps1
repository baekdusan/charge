# Charge 수집기를 Windows 작업 스케줄러에 등록한다 (5분 간격).
# 실행: PowerShell에서 .\install.ps1  (실행 정책 오류 시: powershell -ExecutionPolicy Bypass -File install.ps1)
$ErrorActionPreference = "Stop"

$taskName = "ChargeCollector"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$node = (Get-Command node).Source
$log = Join-Path $env:USERPROFILE "charge-collector.log"

# cmd /c 로 감싸 로그 리다이렉션 (작업 스케줄러는 자체 리다이렉션이 없음)
$arg = "/c `"`"$node`" `"$scriptDir\collect.js`" >> `"$log`" 2>&1`""
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $arg
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

Write-Host "등록 완료: $taskName (5분 간격). 로그: $log"
Write-Host "해제하려면: Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
