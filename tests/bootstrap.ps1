$ErrorActionPreference = 'Stop'
$version = '5.9.0'
$sha256  = '5A0FD80B361600BF4BBD4C307C1FD01B17F11668BAB19E657ADD41B00AD22AB9'
$root    = Join-Path $PSScriptRoot ".modules\Pester\$version"
$marker  = Join-Path $root '.complete'

if (-not (Test-Path $marker)) {
    $key = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))).Replace('-', '')
    $mutex = New-Object Threading.Mutex($false, "Global\scoop_shishi_pester_$key")
    $held  = $false
    try {
        try {
            $held = $mutex.WaitOne([TimeSpan]::FromMinutes(5))
        } catch [Threading.AbandonedMutexException] {
            $held = $true
        }
        if (-not $held) { throw "Pester の用意が 5 分以内に終わらなかった。別プロセスが停止している可能性がある" }

        if (-not (Test-Path $marker)) {
            Get-ChildItem (Split-Path $root) -Filter ".stage-$version-*" -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }

            $stamp = [Guid]::NewGuid().ToString('n')
            $base  = Split-Path $root
            New-Item $base -ItemType Directory -Force | Out-Null
            $zip   = Join-Path $base ".stage-$version-$stamp.zip"
            $stage = Join-Path $base ".stage-$version-$stamp"
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest "https://www.powershellgallery.com/api/v2/package/Pester/$version" -OutFile $zip -UseBasicParsing
                $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
                if ($actual -ne $sha256) { throw "Pester $version のハッシュが一致しない: $actual" }

                Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
                if (-not (Test-Path (Join-Path $stage 'Pester.psd1'))) { throw "展開結果に Pester.psd1 が無い" }

                New-Item (Join-Path $stage '.complete') -ItemType File | Out-Null
                [IO.Directory]::Move($stage, $root)
            } finally {
                foreach ($p in $zip, $stage) {
                    if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    } finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
Import-Module (Join-Path $root 'Pester.psd1') -Force
