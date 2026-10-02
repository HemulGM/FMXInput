param(
    [ValidateSet('Win32', 'Win64', 'Linux64', 'OSX64', 'OSXARM64')]
    [string[]] $Targets = @('Win32', 'Win64', 'Linux64', 'OSX64', 'OSXARM64'),
    [switch] $NativeProbe,
    [string] $OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $taskRoot 'build' }
$taskCompilers = @{
    Win32 = 'dcc32'; Win64 = 'dcc64'; Linux64 = 'dcclinux64'
    OSX64 = 'dccosx64'; OSXARM64 = 'dccosxarm64'
}

foreach ($taskTarget in $Targets) {
    $taskCompiler = $taskCompilers[$taskTarget]
    $taskOutput = [IO.Path]::GetFullPath((Join-Path $OutputDirectory $taskTarget))
    New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
    $taskFlags = @('-B', '-$Q+', '-$R+', "-U$taskRoot", "-N0$taskOutput")
    $taskLog = & $taskCompiler @taskFlags (Join-Path $taskRoot 'FMXInput.pas')
    $taskStatus = $LASTEXITCODE
    $taskLog | Set-Content -LiteralPath (Join-Path $taskOutput 'units.log')
    if ($taskStatus -ne 0 -or $taskLog -match '\b(Hint|Warning|Error|Fatal):') {
        $taskLog | Write-Output
        throw "$taskTarget module compilation failed or produced diagnostics"
    }
    Write-Output "$taskTarget modules compiled with Q+/R+"
    if ($taskTarget -notin @('Win32', 'Win64')) { continue }
    $taskPrograms = @('tests\InputTests.dpr')
    if ($NativeProbe) { $taskPrograms += 'examples\InputProbe.dpr' }
    foreach ($taskProgram in $taskPrograms) {
        $taskName = [IO.Path]::GetFileNameWithoutExtension($taskProgram)
        $taskLog = & $taskCompiler @taskFlags "-E$taskOutput" (Join-Path $taskRoot $taskProgram)
        $taskStatus = $LASTEXITCODE
        $taskLog | Set-Content -LiteralPath (Join-Path $taskOutput "$taskName.log")
        if ($taskStatus -ne 0 -or $taskLog -match '\b(Hint|Warning|Error|Fatal):') {
            $taskLog | Write-Output
            throw "$taskTarget $taskName compilation failed or produced diagnostics"
        }
        & (Join-Path $taskOutput "$taskName.exe")
        if ($LASTEXITCODE -ne 0) { throw "$taskTarget $taskName failed" }
    }
}
