# Charge 수집기를 Windows 작업 스케줄러에 등록한다 (5분 간격).
# 실행: PowerShell에서 .\install.ps1  (실행 정책 오류 시: powershell -ExecutionPolicy Bypass -File install.ps1)
#
# 이 파일은 UTF-8 BOM으로 저장해야 한다 — cli.js가 부르는 Windows PowerShell 5.1은
# BOM이 없으면 시스템 ANSI 코드페이지로 읽어서 아래 한글 안내가 전부 깨진다.
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

$logDir = if ($env:CHARGE_HOME) { $env:CHARGE_HOME } else { Join-Path $env:USERPROFILE ".charge" }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "collector.log"
$logOld = $log + ".old"

# 예전 이름(ChargeCollector)·예전 로그 위치의 잔재가 있으면 정리
Unregister-ScheduledTask -TaskName "ChargeCollector" -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $env:USERPROFILE "charge-connect.log")

# cmd /c 로 감싸 로그 리다이렉션 (작업 스케줄러는 자체 리다이렉션이 없음).
# 매 실행마다 직전 로그를 .old 로 밀고 새로 쓴다 — 5분마다 도는 작업이라 이어 붙이면
# 로그가 끝없이 자란다. 직전 1회분이 남으므로 문제 추적에는 충분하다.
$arg = "/c `"move /y `"$log`" `"$logOld`" >nul 2>&1 & `"$node`" `"$scriptDir\collect.js`" > `"$log`" 2>&1`""
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $arg
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

function Register-ChargeTask([switch]$Background) {
    $p = @{ TaskName = $taskName; Action = $action; Trigger = $trigger; Settings = $settings; Force = $true }
    if ($Background) {
        # 기본값(LogonType Interactive)으로 등록하면 cmd.exe 창이 5분마다 화면에 뜬다.
        # S4U는 대화형 세션 없이 실행돼 창이 뜨지 않고, 로그오프 상태에서도 수집이 돈다.
        $p.Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType S4U -RunLevel Limited
    }
    Register-ScheduledTask @p | Out-Null
}

function Get-LogState {
    $s = ""
    foreach ($f in @($log, $logOld)) {
        if (Test-Path $f) { $i = Get-Item $f; $s += "$($i.Length):$($i.LastWriteTime.Ticks);" } else { $s += "-;" }
    }
    return $s
}

# 등록에 성공해도 실행은 실패할 수 있다. S4U 로그온에는 '일괄 작업으로 로그온'
# (SeBatchLogonRight) 권한이 필요한데, 비관리자 계정이나 GPO로 제한된 PC에서는
# 등록만 통과하고 실행이 매번 0x80070569로 죽는다. 그때는 cmd 자체가 안 떠서
# 로그도 안 남기 때문에, 확인하지 않으면 수집이 조용히 영영 멈춘다.
# 그래서 실제로 한 번 돌려보고 cmd가 떴다는 증거(로그 파일 변화)를 확인한다.
function Test-ChargeTaskRuns {
    $before = Get-LogState
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if ((Get-LogState) -ne $before) { return $true }
        $r = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
        # 0x80070569 요청한 로그온 유형이 부여되지 않음 / 0x8007052E 로그온 실패
        if ($r -eq 2147943785 -or $r -eq 2147943726) { return $false }
        # 0x41301 실행 중 = 프로세스가 떴다는 뜻
        if ($r -eq 267009) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$background = $true
try {
    Register-ChargeTask -Background
} catch {
    Write-Host "백그라운드 실행 등록 실패: $($_.Exception.Message)"
    $background = $false
}
if ($background -and -not (Test-ChargeTaskRuns)) {
    Write-Host "백그라운드 실행 권한이 없어 대화형 모드로 되돌립니다."
    $background = $false
}
if (-not $background) {
    try {
        Register-ChargeTask
        Start-ScheduledTask -TaskName $taskName
    } catch {
        Write-Host "작업 스케줄러 등록에 실패했습니다: $($_.Exception.Message)"
        Write-Host "수동으로 수집하려면: node `"$scriptDir\collect.js`""
        exit 1
    }
    Write-Host "참고: 5분마다 콘솔 창이 잠깐 보일 수 있습니다 (백그라운드 실행 권한이 없는 환경)."
}

Write-Host "등록 완료: $taskName (5분 간격). 로그: $log"
Write-Host "해제하려면: Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
