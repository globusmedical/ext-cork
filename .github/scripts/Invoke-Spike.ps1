param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$InstallV140
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program exited with $LASTEXITCODE"
    }
}

$root = (Resolve-Path "$PSScriptRoot/../..").Path
Set-Location $root
$logs = "$root/build/spike-logs/$Configuration"
New-Item -ItemType Directory -Force $logs | Out-Null
Start-Transcript -Path "$logs/transcript.txt" -Force | Out-Null
$verdict = 'FAILED'
$failure = $null

try {
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    $visualStudio = & $vswhere -latest -products '*' -property installationPath
    if (-not $visualStudio) {
        throw 'Visual Studio is not installed.'
    }
    $legacyTools = "$visualStudio/VC/Auxiliary/Build/Microsoft.VCToolsVersion.v140.default.txt"
    $legacyCompiler = "${env:ProgramFiles(x86)}/Microsoft Visual Studio 14.0/VC/bin/amd64/cl.exe"
    if (-not (Test-Path $legacyTools) -and -not (Test-Path $legacyCompiler)) {
        if (-not $InstallV140) {
            throw 'VC.140 is missing. Installation is opt-in with -InstallV140.'
        }
        $installer = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/setup.exe"
        $process = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
            'modify', '--installPath', "`"$visualStudio`"",
            '--add', 'Microsoft.VisualStudio.Component.VC.140',
            '--quiet', '--norestart', '--nocache'
        )
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "VC.140 installation failed with $($process.ExitCode)"
        }
    }

    $vcvars = "$visualStudio/VC/Auxiliary/Build/vcvarsall.bat"
    $command = "call `"$vcvars`" x64 10.0.17763.0 -vcvars_ver=14.0 && set"
    $developerEnvironment = & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) {
        throw 'Cannot activate the v140 x64 developer environment with SDK 17763.'
    }
    foreach ($line in $developerEnvironment) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }

    $compiler = (Get-Command cl.exe).Source
    $linker = (Get-Command link.exe).Source
    $compilerVersion = (Get-Item $compiler).VersionInfo.FileVersion
    if ($compilerVersion -notmatch '^19[.]0' -or
        (Split-Path $compiler) -ne (Split-Path $linker)) {
        throw "Expected the v140 compiler and matching linker, got $compiler and $linker"
    }
    if ($env:WindowsSDKVersion.TrimEnd('\') -ne '10.0.17763.0') {
        throw "Expected SDK 17763, got $env:WindowsSDKVersion"
    }
    Write-Output "Compiler: $compiler ($compilerVersion)"
    Write-Output "Linker: $linker ($((Get-Item $linker).VersionInfo.FileVersion))"
    Write-Output "Windows SDK: $env:WindowsSDKVersion"

    $baseline = (Get-Content "$root/vcpkg-configuration.json" -Raw |
        ConvertFrom-Json).'default-registry'.baseline
    $env:VCPKG_ROOT = "$root/build/vcpkg"
    if (-not (Test-Path "$env:VCPKG_ROOT/.git")) {
        Invoke-Checked git @('clone', '--no-checkout', 'https://github.com/microsoft/vcpkg', $env:VCPKG_ROOT)
    }
    Invoke-Checked git @('-C', $env:VCPKG_ROOT, 'checkout', '--detach', $baseline)
    Invoke-Checked "$env:VCPKG_ROOT/bootstrap-vcpkg.bat" @('-disableMetrics')
    $env:VCPKG_DISABLE_METRICS = '1'
    $env:VCPKG_BINARY_SOURCES = 'clear'

    Invoke-Checked cmake @(
        "-DSDK_HELPER=$env:VCPKG_ROOT/scripts/cmake/vcpkg_get_windows_sdk.cmake",
        '-P', "$root/tests/spike/check-sdk-selection.cmake"
    )

    $preset = "windows-msvc-$($Configuration.ToLowerInvariant())"
    $build = "$root/build/$preset"
    $prefix = "$root/install/windows-x64"
    Invoke-Checked cmake @('--preset', $preset)
    Invoke-Checked cmake @('--build', '--preset', $preset, '--parallel', '2', '--verbose')
    Invoke-Checked cmake @('--install', $build)

    $mpirBin = "$build/vcpkg_installed/x64-windows-v140/bin"
    if ($Configuration -eq 'Debug') {
        $mpirBin = "$build/vcpkg_installed/x64-windows-v140/debug/bin"
    }
    $env:PATH = "$prefix/bin/$Configuration;$mpirBin;$env:PATH"
    Invoke-Checked ctest @('--preset', $preset)
    Invoke-Checked cmake @(
        "-DPREFIX=$prefix", "-DCONFIG=$Configuration", "-DLOG_DIR=$logs",
        "-DDEFINITION=$root/cmake/cork.def",
        "-DDUMPBIN=$((Get-Command dumpbin.exe).Source)",
        "-DLIB_TOOL=$((Get-Command lib.exe).Source)",
        '-P', "$root/tests/spike/verify-binaries.cmake"
    )

    foreach ($consumer in @('msvc', 'clang-cl')) {
        $consumerBuild = "$root/build/consumer-$consumer-$Configuration"
        $arguments = @(
            '-S', "$root/tests/spike", '-B', $consumerBuild, '-G', 'Ninja',
            "-DCMAKE_PREFIX_PATH=$prefix", "-DCMAKE_BUILD_TYPE=$Configuration"
        )
        if ($consumer -eq 'clang-cl') {
            $clang = (Get-Command clang-cl.exe).Source
            $lld = Join-Path (Split-Path $clang) 'lld-link.exe'
            $arguments += @("-DCMAKE_CXX_COMPILER=$clang", "-DCMAKE_LINKER=$lld")
        }
        Invoke-Checked cmake $arguments
        Invoke-Checked cmake @('--build', $consumerBuild, '--verbose')
        Invoke-Checked ctest @('--test-dir', $consumerBuild, '--output-on-failure')
    }

    $buildInfo = [ordered]@{
        sourceCommit    = (& git rev-parse HEAD)
        configuration   = $Configuration
        compiler        = $compiler
        compilerVersion = $compilerVersion
        linker          = $linker
        linkerVersion   = (Get-Item $linker).VersionInfo.FileVersion
        windowsSdk      = $env:WindowsSDKVersion
        cmake           = (& cmake --version | Select-Object -First 1)
        ninja           = (& ninja --version)
        vcpkgCommit     = $baseline
        mpirRuntime     = 'mpir.dll'
        mpirPort        = (Get-Content "$env:VCPKG_ROOT/ports/mpir/vcpkg.json" -Raw | ConvertFrom-Json)
        runnerImage     = [Environment]::GetEnvironmentVariable('ImageVersion')
        clangVersion    = (& clang-cl --version | Select-Object -First 1)
    }
    $buildInfo | ConvertTo-Json -Depth 10 | Set-Content "$prefix/build-info-$Configuration.json"
    $verdict = 'PASS'
}
catch {
    $failure = $_.Exception.Message
    Write-Output "Spike failed: $failure"
}
finally {
    [ordered]@{
        verdict       = $verdict
        configuration = $Configuration
        failure       = $failure
    } | ConvertTo-Json | Set-Content "$logs/result.json"
    $summary = @(
        "## v140 Spike: $verdict ($Configuration)",
        '',
        'Scope: build, exports, import library, installed MSVC and clang-cl consumers.',
        'No geometry-equivalence claim is made by this spike.'
    )
    if ($failure) {
        $summary += "Failure: $failure"
    }
    $summary | Set-Content "$logs/summary.md"
    if ([Environment]::GetEnvironmentVariable('GITHUB_STEP_SUMMARY')) {
        $summary | Add-Content $env:GITHUB_STEP_SUMMARY
    }
    Stop-Transcript | Out-Null
}
if ($verdict -ne 'PASS') {
    throw $failure
}
