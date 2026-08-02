BeforeAll {
    $manifest = Get-Content (Join-Path (Split-Path $PSScriptRoot) 'bucket\biz-udgothic.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $lines = $manifest.installer.script
    # function Get-FontFullName の開始行から、対応する閉じ括弧の行までを切り出す
    $start = ($lines | Select-String -SimpleMatch 'function Get-FontFullName').LineNumber - 1
    $depth = 0; $end = $null
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $depth += ([regex]::Matches($lines[$i], '\{')).Count
        $depth -= ([regex]::Matches($lines[$i], '\}')).Count
        if ($depth -eq 0 -and $i -gt $start) { $end = $i; break }
    }
    if ($null -eq $end) { throw 'Get-FontFullName の範囲を特定できなかった' }
    . ([scriptblock]::Create(($lines[$start..$end] -join "`n")))

    $script:Scratch = Join-Path $env:TEMP ("fontname-" + [Guid]::NewGuid().ToString('n'))
    New-Item $script:Scratch -ItemType Directory -Force | Out-Null

    function New-BrokenFont([string]$Name, [byte[]]$Bytes) {
        $p = Join-Path $script:Scratch $Name
        [IO.File]::WriteAllBytes($p, $Bytes)
        return $p
    }
}

AfterAll {
    if ($script:Scratch -and (Test-Path $script:Scratch)) {
        Remove-Item $script:Scratch -Recurse -Force
    }
}

Describe 'Get-FontFullName' -Tag 'Static' {
    It '実在のフォントから Full font name を読める' {
        # 特定の 1 ファイルを直書きしない。BIZ UDGothic は OS 同梱ではなく手で
        # machine-wide へ入れられていただけで、それを片付けたらこの検査が
        # 黙って skip になった(実測)。Windows が必ず持つものから選ぶ。
        # 期待値はファイルごとに違うので、ファイル名と Full font name を対で持つ
        $sample = $null
        foreach ($c in @(
            @{ File = 'segoeui.ttf'; Full = 'Segoe UI' },
            @{ File = 'arial.ttf';   Full = 'Arial' },
            @{ File = 'tahoma.ttf';  Full = 'Tahoma' }
        )) {
            $p = Join-Path $env:WINDIR "Fonts\$($c.File)"
            if (Test-Path -LiteralPath $p) { $sample = $c; $sample.Path = $p; break }
        }
        if (-not $sample) { throw '検証に使える OS 同梱フォントが見つからない' }

        Get-FontFullName $sample.Path | Should -Be $sample.Full
    }

    It '12 バイト未満なら例外' {
        $p = New-BrokenFont 'tiny.ttf' ([byte[]](1..8))
        { Get-FontFullName $p } | Should -Throw '*短すぎる*'
    }

    It 'TTC は明示的に拒否する' {
        $b = New-Object byte[] 64
        [Text.Encoding]::ASCII.GetBytes('ttcf').CopyTo($b, 0)
        $p = New-BrokenFont 'collection.ttc' $b
        { Get-FontFullName $p } | Should -Throw '*TTC は非対応*'
    }

    It 'name テーブルが無ければ例外' {
        # sfnt ヘッダのみ。テーブル数 0
        $b = New-Object byte[] 32
        $b[0] = 0; $b[1] = 1; $b[2] = 0; $b[3] = 0    # version 1.0
        $b[4] = 0; $b[5] = 0                          # numTables = 0
        $p = New-BrokenFont 'notable.ttf' $b
        { Get-FontFullName $p } | Should -Throw '*name テーブルが無い*'
    }

    It 'ファイル名へフォールバックしない' {
        $p = New-BrokenFont 'ShouldNotBeUsed.ttf' ([byte[]](1..8))
        { Get-FontFullName $p } | Should -Throw
        # 例外を投げること自体が要件。戻り値としてファイル名を返してはならない
    }

    It '合成した最小 sfnt からも Full font name を読める（実機の BIZ UDGothic に依存しない回帰防止）' {
        # 「実在のフォントから読める」テストは C:\Windows\Fonts\BIZUDGothic-Regular.ttf の
        # 有無に依存し、無い環境や TTC 配布に変わった環境では Skipped になる。
        # そうなると「有効な TTF を全て拒否する」regression があってもスイートは通ってしまうため、
        # 最小限の自前 sfnt（sfnt header 1 テーブル + name テーブル 1 レコード）で成功経路を独立に担保する
        $b = New-Object byte[] 64
        $b[0] = 0; $b[1] = 1; $b[2] = 0; $b[3] = 0        # sfnt version 1.0
        $b[4] = 0; $b[5] = 1                              # numTables = 1
        $b[6] = 0; $b[7] = 16                             # searchRange = 16 (numTables=1 のとき)
        $b[8] = 0; $b[9] = 0                               # entrySelector = 0
        $b[10] = 0; $b[11] = 0                             # rangeShift = 0
        [Text.Encoding]::ASCII.GetBytes('name').CopyTo($b, 12)   # table tag
        $b[16] = 0x01; $b[17] = 0xA4; $b[18] = 0x05; $b[19] = 0xE9   # checksum（name テーブル 36 バイトぶんの実値）
        $b[20] = 0; $b[21] = 0; $b[22] = 0; $b[23] = 28   # table offset -> name テーブルは 28 から
        $b[24] = 0; $b[25] = 0; $b[26] = 0; $b[27] = 36   # table length = 36 バイト（パーサーは未使用だが正しい sfnt にするため設定）
        $b[28] = 0; $b[29] = 0                            # name table format = 0
        $b[30] = 0; $b[31] = 1                            # name record count = 1
        $b[32] = 0; $b[33] = 18                           # stringOffset（レコード 1 件ぶん = 6 + 12）
        $b[34] = 0; $b[35] = 3                            # platformID = 3 (Windows)
        $b[36] = 0; $b[37] = 1                            # encodingID
        $b[38] = 4; $b[39] = 9                            # languageID = 0x0409
        $b[40] = 0; $b[41] = 4                            # nameID = 4 (Full font name)
        $strBytes = [Text.Encoding]::BigEndianUnicode.GetBytes('Test Font')
        $b[42] = 0; $b[43] = [byte]$strBytes.Length       # length
        $b[44] = 0; $b[45] = 0                            # offset（文字列格納域からの相対位置）
        $strBytes.CopyTo($b, 46)
        $p = New-BrokenFont 'synthetic.ttf' $b
        Get-FontFullName $p | Should -Be 'Test Font'
    }

    It 'name テーブルに nameID 4 が無ければ例外（ファイル名フォールバック禁止の担保）' {
        # 上の合成 sfnt テストと同じ形状で、name レコードの nameID だけを
        # 4 (Full font name) ではなく 1 (Font Family name) にする。
        # length/ttcf/テーブルディレクトリ走査/name テーブル特定/文字列オフセット境界
        # まではすべて正常に通過し、最後の「nameID 4 が無い」チェックだけで落ちることを確認する
        $b = New-Object byte[] 64
        $b[0] = 0; $b[1] = 1; $b[2] = 0; $b[3] = 0        # sfnt version 1.0
        $b[4] = 0; $b[5] = 1                              # numTables = 1
        $b[6] = 0; $b[7] = 16                             # searchRange = 16 (numTables=1 のとき)
        $b[8] = 0; $b[9] = 0                               # entrySelector = 0
        $b[10] = 0; $b[11] = 0                             # rangeShift = 0
        [Text.Encoding]::ASCII.GetBytes('name').CopyTo($b, 12)   # table tag
        $b[16] = 0x01; $b[17] = 0xA1; $b[18] = 0x05; $b[19] = 0xE9   # checksum（nameID=1 に変えたぶん上の合成テストから差し替え済みの実値）
        $b[20] = 0; $b[21] = 0; $b[22] = 0; $b[23] = 28   # table offset -> name テーブルは 28 から
        $b[24] = 0; $b[25] = 0; $b[26] = 0; $b[27] = 36   # table length = 36 バイト（パーサーは未使用だが正しい sfnt にするため設定）
        $b[28] = 0; $b[29] = 0                            # name table format = 0
        $b[30] = 0; $b[31] = 1                            # name record count = 1
        $b[32] = 0; $b[33] = 18                           # stringOffset（レコード 1 件ぶん = 6 + 12）
        $b[34] = 0; $b[35] = 3                            # platformID = 3 (Windows)
        $b[36] = 0; $b[37] = 1                            # encodingID
        $b[38] = 4; $b[39] = 9                            # languageID = 0x0409
        $b[40] = 0; $b[41] = 1                            # nameID = 1 (Font Family name, NOT 4)
        $strBytes = [Text.Encoding]::BigEndianUnicode.GetBytes('Test Font')
        $b[42] = 0; $b[43] = [byte]$strBytes.Length       # length
        $b[44] = 0; $b[45] = 0                            # offset（文字列格納域からの相対位置）
        $strBytes.CopyTo($b, 46)
        $p = New-BrokenFont 'synthetic-no-nameid4.ttf' $b
        { Get-FontFullName $p } | Should -Throw '*nameID 4 が無い*'
    }
}
