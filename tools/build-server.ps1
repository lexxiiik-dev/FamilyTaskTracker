# Сборка сервера для Linux (amd64 и arm64) со встроенным веб-клиентом.
# Результат — папка dist\server: бинарники и всё для установки (install.sh, службы systemd, Docker, Caddy).
# Её целиком копируют на сервер и запускают  sudo bash install.sh  (см. DEPLOY.md).
. "$PSScriptRoot\env.ps1"
$root = Split-Path $PSScriptRoot
$out = "$root\dist\server"
if (-not (Test-Path "$root\app\build\web\index.html")) { & "$PSScriptRoot\build-web.ps1" }
$embed = "$root\server\web"
$keep = [IO.File]::ReadAllText("$embed\index.html")
Push-Location "$root\server"
try {
    # веб-клиент кладётся в server/web на время сборки (go:embed), потом там снова заглушка
    Remove-Item "$embed\*" -Recurse -Force
    Copy-Item "$root\app\build\web\*" $embed -Recurse
    $env:GOOS = 'linux'; $env:CGO_ENABLED = '0'
    New-Item -ItemType Directory -Force $out | Out-Null
    foreach ($arch in 'amd64', 'arm64') {
        $env:GOARCH = $arch
        go build -trimpath -ldflags '-s -w' -o "$out\todod-linux-$arch" ./cmd/todod
        if ($LASTEXITCODE) { throw "сборка $arch не удалась" }
    }
} finally {
    Remove-Item Env:GOOS, Env:GOARCH -ErrorAction SilentlyContinue
    Remove-Item "$embed\*" -Recurse -Force
    [IO.File]::WriteAllText("$embed\index.html", $keep, (New-Object Text.UTF8Encoding($false)))
    Pop-Location
}
Copy-Item "$root\deploy\*" $out -Force
Get-ChildItem $out | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }