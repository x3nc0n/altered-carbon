$escapedPattern = ($nfPattern -replace "'", "''")

$promoteScript = @'
param([string]$EscapedPattern)
...
$entries = ... -and $_.Name -match $EscapedPattern
...
'@

Start-Process pwsh -ArgumentList '-NoProfile','-Command',"& { $promoteScript } -EscapedPattern '$escapedPattern'"