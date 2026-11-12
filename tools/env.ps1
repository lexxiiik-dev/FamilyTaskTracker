# Окружение сборки (Windows, PowerShell). Подключать точкой:  . .\tools\env.ps1
# Нужны Flutter, Go, JDK 17 и Android SDK. Если они уже в PATH, этот файл можно не подключать.
# Свои пути можно задать заранее переменными окружения FLUTTER_ROOT, ANDROID_HOME, JAVA_HOME.
if ($env:FLUTTER_ROOT) { $env:Path = "$env:FLUTTER_ROOT\bin;$env:Path" }
if (-not $env:ANDROID_HOME -and (Test-Path "$env:LOCALAPPDATA\Android\Sdk")) { $env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk" }
if ($env:ANDROID_HOME) {
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:Path = "$env:ANDROID_HOME\platform-tools;$env:ANDROID_HOME\emulator;$env:Path"
}
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CGO_ENABLED = '0'