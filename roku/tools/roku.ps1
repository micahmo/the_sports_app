# Drives the Roku used for development.
#
#   powershell -File roku/tools/roku.ps1 install [zip]        (default: roku/out/sports.zip)
#   powershell -File roku/tools/roku.ps1 screenshot [file]    (default: roku/out/screen.jpg)
#   powershell -File roku/tools/roku.ps1 launch
#
# Settings come from environment variables (process, else your Windows user
# environment, so they work in shells started before you set them):
#   ROKU_HOST            the Roku's IP address
#   ROKU_DEV_USER        developer-mode user (default: rokudev)
#   ROKU_DEV_PASSWORD    developer-mode password
#
# The password is handed to curl on its standard input (curl -K -), so it never
# appears on a command line, in the output, or in this file.
param(
    [Parameter(Mandatory = $true)][ValidateSet('install', 'screenshot', 'launch')][string]$Command,
    [string]$Path
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # roku/

function Get-Setting([string]$name, [string]$default = '') {
    $v = [Environment]::GetEnvironmentVariable($name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name, 'User') }
    if (-not $v) { $v = $default }
    return $v
}

$rokuHost = Get-Setting 'ROKU_HOST'
if (-not $rokuHost) { throw 'Set ROKU_HOST to the Roku''s IP address.' }

# curl with the developer-mode login, which goes in on stdin as a config line.
function Invoke-Dev([string[]]$curlArgs) {
    $user = Get-Setting 'ROKU_DEV_USER' 'rokudev'
    $pass = Get-Setting 'ROKU_DEV_PASSWORD'
    if (-not $pass) { throw 'Set ROKU_DEV_PASSWORD (developer-mode password).' }
    $cred = ($user + ':' + $pass).Replace('\', '\\').Replace('"', '\"')
    # curl's stdin is written with the console's input encoding, and when that's
    # UTF-8 (as it is when started from some shells) .NET starts the stream with
    # a byte-order mark, which curl rejects. So start curl with a BOM-less one.
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'curl.exe'
    # -w adds the HTTP status as the last line of the output.
    $psi.Arguments = (@('-s', '-S', '--digest', '-K', '-', '-w', '\n%{http_code}') + $curlArgs | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $consoleIn = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
        $p = [System.Diagnostics.Process]::Start($psi)
    } finally { [Console]::InputEncoding = $consoleIn }
    $p.StandardInput.Write('user = "' + $cred + '"' + "`n")
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "curl failed ($($p.ExitCode))" }
    $status = $out.Substring($out.LastIndexOf("`n") + 1).Trim()
    if ($status -eq '401') { throw 'Login rejected: check ROKU_DEV_USER / ROKU_DEV_PASSWORD.' }
    return $out.Substring(0, $out.LastIndexOf("`n"))
}

switch ($Command) {
    'install' {
        if (-not $Path) { $Path = Join-Path $root 'out\sports.zip' }
        $zip = (Resolve-Path $Path).Path
        $html = Invoke-Dev @('-F', 'mysubmit=Install', '-F', "archive=@$zip", "http://$rokuHost/plugin_install")
        # The installer answers with a page; look for its status phrases.
        $text = $html -join "`n"
        if ($text -match 'Install Success') { Write-Output 'Installed.' }
        elseif ($text -match 'Identical to previous version') { Write-Output 'Already installed (identical package).' }
        elseif ($text -match 'Install Failure[^<"]*') { throw "Install failed: $($Matches[0])" }
        else {
            $plain = (($text -replace '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
            throw ('Unexpected reply: ' + $plain.Substring(0, [Math]::Min(200, $plain.Length)))
        }
    }
    'screenshot' {
        if (-not $Path) { $Path = Join-Path $root 'out\screen.jpg' }
        Invoke-Dev @('-F', 'mysubmit=Screenshot', '-F', 'passwd=', '-F', 'archive=', "http://$rokuHost/plugin_inspect", '-o', 'NUL') | Out-Null
        Invoke-Dev @('-o', $Path, "http://$rokuHost/pkgs/dev.jpg") | Out-Null
        # The Roku answers "Error 404" when the dev app isn't running.
        $head = [System.IO.File]::ReadAllBytes((Resolve-Path $Path).Path)[0..1]
        if ($head[0] -ne 0xFF -or $head[1] -ne 0xD8) { Remove-Item $Path; throw 'No screenshot: is the dev app running?' }
        Write-Output "Saved $Path"
    }
    'launch' {
        # External Control Protocol: no login needed.
        # -X POST rather than -d '': Windows PowerShell drops empty arguments.
        & curl.exe -s -S -X POST "http://${rokuHost}:8060/launch/dev" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Launch failed (curl $LASTEXITCODE)" }
        Write-Output 'Launched the dev app.'
    }
}
