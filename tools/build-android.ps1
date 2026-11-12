# Сборка Android-приложения (APK). При первом запуске создаёт ключ подписи:
#   app\android\todo-release.jks и app\android\key.properties — СОХРАНИТЕ их: без того же ключа
#   обновление поверх установленного приложения невозможно.
param([switch]$Debug)
. "$PSScriptRoot\env.ps1"
$root = Split-Path $PSScriptRoot
$android = "$root\app\android"
if (-not (Test-Path "$android\key.properties")) {
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = [Convert]::ToBase64String($bytes).Replace('+', 'x').Replace('/', 'y').Replace('=', '')
    & "$env:JAVA_HOME\bin\keytool.exe" -genkeypair -v -keystore "$android\todo-release.jks" -storetype PKCS12 -keyalg RSA -keysize 2048 `
        -validity 20000 -alias todo -storepass $pw -keypass $pw -dname 'CN=Todo' 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw 'keytool failed' }
    [IO.File]::WriteAllText("$android\key.properties", "storeFile=todo-release.jks`nstorePassword=$pw`nkeyAlias=todo`nkeyPassword=$pw`n", (New-Object Text.UTF8Encoding($false)))
    'release key created: app\android\todo-release.jks'
}
Push-Location "$root\app"
try {
    if ($Debug) { flutter build apk --debug } else { flutter build apk --release }
    if ($LASTEXITCODE) { throw 'flutter build apk failed' }
    Get-ChildItem "$root\app\build\app\outputs\flutter-apk\*.apk" | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
} finally { Pop-Location }
