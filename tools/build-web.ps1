# Сборка веб-клиента (PWA). Его отдаёт сам сервер по корневому адресу: build-server.ps1 встраивает его в программу.
. "$PSScriptRoot\env.ps1"
$root = Split-Path $PSScriptRoot
Push-Location "$root\app"
try {
    # движок отрисовки кладётся рядом (без CDN): веб-версия работает без доступа к интернету
    flutter build web --release --base-href / --no-web-resources-cdn --pwa-strategy=none
    if ($LASTEXITCODE) { throw 'flutter build web failed' }
    $web = "$root\app\build\web"
    $files = Get-ChildItem $web -Recurse -File |
        Where-Object { $_.Name -notin 'sw.js', 'flutter_service_worker.js', '.last_build_id', 'NOTICES' -and $_.Extension -notin '.map', '.symbols' -and $_.FullName -notmatch '\\webparagraph\\' -and $_.Name -notmatch '^(skwasm|wimp)' } |
        ForEach-Object { $_.FullName.Substring($web.Length + 1).Replace('\', '/') } |
        Where-Object { $_ -ne 'index.html' }
    $list = '[' + ((@('./') + $files | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
    $ver = (Get-Date).ToString('yyyyMMddHHmmss')
    $sw = [IO.File]::ReadAllText("$web\sw.js").Replace("'__VERSION__'", "'$ver'").Replace('__FILES__', $list)
    [IO.File]::WriteAllText("$web\sw.js", $sw, (New-Object Text.UTF8Encoding($false)))
    Remove-Item "$web\flutter_service_worker.js" -ErrorAction SilentlyContinue
    "web: $($files.Count) files, version $ver, " + [math]::Round(((Get-ChildItem $web -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1) + ' MB'
} finally { Pop-Location }