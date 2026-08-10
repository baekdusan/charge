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

# node 를 직접 실행하고 로그는 collect.js 가 --log 로 직접 쓴다.
# cmd /c 로 감싸 리다이렉션하면 경로 안의 %VAR% 가 확장되고, move 실패가 조용히 묻히고,
# 실행이 겹칠 때 로그 잠금으로 출력이 통째로 사라진다. 셸을 안 거치면 그 셋이 모두 없어진다.
$arg = "`"$scriptDir\collect.js`" --log `"$log`""
$action = New-ScheduledTaskAction -Execute $node -Argument $arg -WorkingDirectory $scriptDir
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

function Register-ChargeTask([switch]$Background) {
    $p = @{ TaskName = $taskName; Action = $action; Trigger = $trigger; Settings = $settings; Force = $true }
    if ($Background) {
        # 기본값(LogonType Interactive)으로 등록하면 콘솔 창이 5분마다 화면에 뜬다.
        # S4U는 대화형 세션 없이 실행돼 창이 뜨지 않고, 로그오프 상태에서도 수집이 돈다.
        $p.Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType S4U -RunLevel Limited
    }
    Register-ScheduledTask @p | Out-Null
}

function Get-LogState {
    $s = ""
    foreach ($f in @($log, $logOld)) {
        # Test-Path 로 확인하고 Get-Item 을 따로 부르면, 그 사이 수집기가 로그를 밀었을 때
        # ErrorActionPreference='Stop' 에 걸려 설치가 통째로 죽는다. 한 번에 가져온다.
        $i = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue
        if ($i) { $s += "$($i.Length):$($i.LastWriteTime.Ticks);" } else { $s += "-;" }
    }
    return $s
}

# 등록에 성공해도 실행은 실패할 수 있다. S4U 로그온에는 '일괄 작업으로 로그온'
# (SeBatchLogonRight) 권한이 필요한데, 비관리자 계정이나 GPO로 제한된 PC에서는
# 등록만 통과하고 실행이 매번 0x80070569로 죽는다. 그때는 프로세스 자체가 안 떠서
# 로그도 안 남기 때문에, 확인하지 않으면 수집이 조용히 영영 멈춘다.
# 그래서 실제로 한 번 돌려보고 프로세스가 떴다는 증거(로그 파일 변화)를 확인한다.
function Test-ChargeTaskRuns {
    # 예전 정의로 돌던 인스턴스가 남아 있으면 그쪽 출력을 새 작업의 성공으로 오인한다
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    $before = Get-LogState
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        # collect.js 는 뜨자마자 로그에 시작 줄을 남긴다 — 프로세스가 떴다는 직접 증거.
        # '실행 중(0x41301)' 상태만으로 성공 처리하면 남아 있던 인스턴스에 속을 수 있다.
        if ((Get-LogState) -ne $before) { return $true }
        $r = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
        # 0x80070569 요청한 로그온 유형이 부여되지 않음 / 0x8007052E 로그온 실패
        if ($r -eq 2147943785 -or $r -eq 2147943726) { return $false }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

$background = $true
$adminRetryHint = $false
try {
    Register-ChargeTask -Background
} catch {
    Write-Host "백그라운드 실행 등록 실패: $($_.Exception.Message)"
    # 비관리자 PowerShell에서는 S4U(창 없는) 등록이 항상 거부된다 — 같은 계정을 관리자
    # 권한으로 승격해 재실행하면 해결되므로 그때만 안내한다. 판별은 토큰 Claims의
    # Administrators SID(S-1-5-32-544)로 한다 — UAC 필터드 토큰에서 이 그룹은 deny-only로
    # 강등되는데 .Groups는 deny-only를 걸러내 버리고, .Claims에는 DenyOnlySid로 남는다.
    # 표준 사용자(Claims에 아예 없음)에게 안내하면 다른 관리자 계정으로 승격해 그 계정
    # 프로필로 작업을 덮어쓰게 되고, 아래 Test-ChargeTaskRuns 폴백(SeBatchLogonRight 부재)은
    # 승격으로 해결되지 않는다 — 두 경우 모두 안내하지 않는다.
    $adminRetryHint = [Security.Principal.WindowsIdentity]::GetCurrent().Claims.Value -contains "S-1-5-32-544"
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
    if ($adminRetryHint) {
        Write-Host "창이 뜨지 않게 하려면: 관리자 권한 PowerShell에서 아래를 한 번 실행하세요."
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$scriptDir\install.ps1`""
    }
}

Write-Host "등록 완료: $taskName (5분 간격). 로그: $log"
Write-Host "해제하려면: Unregister-ScheduledTask -TaskName $taskName -Confirm:`$false"
