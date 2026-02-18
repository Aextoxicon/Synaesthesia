$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$ProjectRoot = Split-Path $ScriptDir -Parent

Set-Location $ProjectRoot

Write-Host "run all test"
Write-Host "current dir: $(Get-Location)"

flutter test test/unit/

if ($LASTEXITCODE -eq 0) {
    Write-Host "all tests passed"
} else {
    Write-Host "tests failed"
    exit 1
}