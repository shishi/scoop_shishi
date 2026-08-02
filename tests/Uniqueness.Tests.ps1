BeforeAll {
    $script:Entries = Get-Content (Join-Path $PSScriptRoot 'fixtures\zip-entries.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:All = @()
    foreach ($p in $script:Entries.PSObject.Properties) {
        foreach ($f in $p.Value.files) {
            $script:All += [pscustomobject]@{ Manifest = $p.Name; File = $f }
        }
    }
    # 共通スクリプトが登録するのは 35 を含まないものだけ
    $script:Registered = @($script:All | Where-Object { $_.File -notmatch '35' })
    # フィクスチャは静的ファイルなので、manifest の追加・削除だけでなく、Excavator が
    # version を上げた後もフィクスチャが古い URL の内容のまま緑であり続けないよう、
    # 記録された version を manifest の現在の version と突き合わせる(下の It)。
    # URL の中身そのものの変更(version 据え置きでの差し替えなど)までは検知できない。
    # 検知には再生成が要る点は tests/tools/zip_entries.py 参照
    $script:BucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
    $script:CurrentFontManifests = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
        Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') } |
        ForEach-Object { $_.BaseName } | Sort-Object)
}

Describe 'bucket 全体の一意性' -Tag 'Static' {
    It 'フィクスチャに 16 manifest ぶんある' {
        @($script:Entries.PSObject.Properties).Count | Should -Be 16
    }

    It '配布されるフォントファイルは 217 個' {
        $script:All.Count | Should -Be 217
    }

    It '実際に登録されるのは 125 個' {
        $script:Registered.Count | Should -Be 125
    }

    It '登録されるファイル名が bucket 全体で重複しない' {
        $dup = $script:Registered | Group-Object File | Where-Object { $_.Count -gt 1 }
        $detail = ($dup | ForEach-Object {
            "$($_.Name) -> " + (($script:Registered | Where-Object File -eq $_.Name).Manifest -join ', ')
        }) -join '; '
        $detail | Should -BeNullOrEmpty
    }

    It '35 を含むファイルが 92 個除外される' {
        @($script:All | Where-Object { $_.File -match '35' }).Count | Should -Be 92
    }

    It 'Discord は除外されない' {
        @($script:Registered | Where-Object { $_.File -match 'Discord' }).Count | Should -Be 4
    }

    It 'フィクスチャの manifest 集合が bucket の現在のフォント manifest と一致する' {
        $fixtureNames = @($script:Entries.PSObject.Properties.Name | Sort-Object)
        $diff = Compare-Object $script:CurrentFontManifests $fixtureNames
        $detail = ($diff | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '; '
        $detail | Should -BeNullOrEmpty
    }

    It 'フィクスチャに記録した version が manifest の現在の version と一致する' {
        # このフィクスチャは静的スナップショットなので、Excavator が hourly で
        # version/url/hash を書き換えた後も再生成しなければ古い URL の内容のまま
        # 残り続ける。それに気づかず緑であり続けると、上のファイル名衝突検査などが
        # 現実と無関係なスナップショットに対して意味なく通り続けてしまう。
        # version の食い違いでそれを検知し、再生成(tests/tools/zip_entries.py)を促す
        $mismatched = @()
        foreach ($p in $script:Entries.PSObject.Properties) {
            $manifestPath = Join-Path $script:BucketDir ($p.Name + '.json')
            if (-not (Test-Path $manifestPath)) { continue }  # manifest 集合自体の差分は上の It が検知する
            $current = (Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).version
            if ($p.Value.version -ne $current) {
                $mismatched += "$($p.Name): フィクスチャ=$($p.Value.version) 現行=$current"
            }
        }
        ($mismatched -join '; ') | Should -BeNullOrEmpty
    }
}
