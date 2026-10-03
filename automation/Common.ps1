Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-MicrosoftUrl([string] $Url) {
    $uri = [uri] $Url
    if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or
        $uri.Host -notmatch '^(aka\.ms|dotnetcli\.blob\.core\.windows\.net|([a-z0-9-]+\.)*microsoft\.com|([a-z0-9-]+\.)*windowsupdate\.com)$') {
        throw "Not an HTTPS Microsoft source: $Url"
    }
}

function Get-DotNetChannels($Index) {
    $channels = @($Index.'releases-index' | Where-Object {
        $_.'support-phase' -in @('active', 'maintenance', 'eol') -and
        $_.'channel-version' -match '^\d+\.\d+$' -and
        [version] $_.'channel-version' -ge [version] '6.0' -and
        $_.'latest-release' -match '^\d+\.\d+\.\d+$'
    } | Sort-Object { [version] $_.'channel-version' })
    if (-not $channels.Count) { throw 'No stable .NET channels from 6.0 in Microsoft metadata' }
    $channels
}

function Get-PreviousDesktopRelease($Metadata, [version] $Version) {
    $channel = "$($Version.Major).$($Version.Minor)."
    $previous = $Metadata.releases | Where-Object {
        $_.PSObject.Properties['windowsdesktop'] -and $_.windowsdesktop.version -match '^\d+\.\d+\.\d+$' -and
        $_.windowsdesktop.version.StartsWith($channel) -and [version] $_.windowsdesktop.version -lt $Version
    } | Sort-Object { [version] $_.windowsdesktop.version } -Descending | Select-Object -First 1
    if (-not $previous -and $Version.Build -ne 0) { throw "No previous stable Desktop patch for $Version in Microsoft metadata." }
    $previous
}

# Check every redirect, not only the first and last host.
function Save-Download([string] $Url, [string] $Path, [switch] $Microsoft, [string] $Sha256) {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('civisrom-vcredist/1.0')
    try {
        for ($redirect = 0; $redirect -le 10; $redirect++) {
            if ($Microsoft) { Assert-MicrosoftUrl $Url }
            $response = $client.GetAsync($Url).GetAwaiter().GetResult()
            try {
                $status = [int] $response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    $Url = [uri]::new([uri] $Url, $response.Headers.Location).AbsoluteUri
                    continue
                }
                $null = $response.EnsureSuccessStatusCode()
                [IO.File]::WriteAllBytes($Path, $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
                if ($Sha256 -and (Get-Sha256 $Path) -ne $Sha256) { throw "SHA256 mismatch: $Path" }
                return $Url
            } finally { $response.Dispose() }
        }
        throw "Too many redirects: $Url"
    } finally { $client.Dispose(); $handler.Dispose() }
}

function Get-DownloadLink([string] $Html, [string] $FileName) {
    $links = @([regex]::Matches($Html, 'https://download\.microsoft\.com/[^\s"<>]+') |
        ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Value) } |
        Where-Object { [IO.Path]::GetFileName(([uri] $_).AbsolutePath) -ieq $FileName } |
        Sort-Object -Unique)
    if ($links.Count -ne 1) { throw "Expected one Microsoft download for $FileName, found $($links.Count)" }
    $links[0]
}

function Assert-MicrosoftSignature([string] $Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        throw "Invalid Microsoft Authenticode signature: $Path ($($signature.Status))"
    }
}

function Invoke-Checked([string] $File, [string[]] $Arguments) {
    & $File @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$File exited with $LASTEXITCODE" }
}

function Get-MsiProperty([object] $Database, [string] $Name) {
    if ($Name -notmatch '^[A-Za-z]+$') { throw 'Invalid MSI property name' }
    $view = $Database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$Name'")
    try {
        $null = $view.Execute()
        $record = $view.Fetch()
        if (-not $record) { throw "Missing MSI property: $Name" }
        [string] $record.StringData(1)
    } finally { $null = $view.Close() }
}

function Get-MsiMetadata([string] $Path) {
    $engine = New-Object -ComObject WindowsInstaller.Installer
    $database = $engine.OpenDatabase($Path, 0)
    try {
        $metadata = [ordered]@{
            productCode = Get-MsiProperty $database 'ProductCode'
            upgradeCode = Get-MsiProperty $database 'UpgradeCode'
            version = Get-MsiProperty $database 'ProductVersion'
            name = Get-MsiProperty $database 'ProductName'
        }
        $null = [guid]::Parse($metadata.productCode)
        $null = [guid]::Parse($metadata.upgradeCode)
        $null = [version]::Parse($metadata.version)
        $metadata
    } finally {
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($database)
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine)
    }
}

function Reset-MsiPackageCode([string] $Path) {
    $engine = New-Object -ComObject WindowsInstaller.Installer
    $summary = $null
    try {
        $summary = $engine.SummaryInformation($Path, 1)
        $code = [guid]::NewGuid().ToString('B').ToUpperInvariant()
        $null = $summary.GetType().InvokeMember('Property', [Reflection.BindingFlags]::SetProperty, $null, $summary, @(9, $code))
        $null = $summary.Persist()
        $code
    } finally {
        if ($summary) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
        $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($engine)
    }
}
