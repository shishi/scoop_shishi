BeforeDiscovery {
    $script:BucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
    $script:ManifestFiles = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
        Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') })
    # フォント以外も含めた全件。下の Describe はフォント専用の共有スクリプトを
    # 見るので除外リストが要るが、bucket 全体に掛かる決まりはこちらで見る
    $script:AllManifestFiles = @(Get-ChildItem $script:BucketDir -Filter '*.json')
}

Describe 'bucket 全体の静的検査' -Tag 'Static' {
    BeforeAll {
        # scoop の Get-VersionSubstitution と同じ表を、scoop の substitute と同じ
        # 素の文字列置換で当てる。substitute が見るのは '$version' のような素の
        # トークンだけで、${version} 形式は展開されない。1 つでも欠けると、その
        # 置換子を使った正しい manifest を嘘の赤で落とすことになる
        $script:ExpandVersion = {
            param([string]$Template, [string]$Version)
            $first = $Version.Split('-') | Select-Object -First 1
            $parts = $first.Split('.')
            $vars = @{
                'version'           = $Version
                'dotVersion'        = ($Version -replace '[._-]', '.')
                'underscoreVersion' = ($Version -replace '[._-]', '_')
                'dashVersion'       = ($Version -replace '[._-]', '-')
                'cleanVersion'      = ($Version -replace '[._-]', '')
                'majorVersion'      = ($parts | Select-Object -First 1)
                'minorVersion'      = ($parts | Select-Object -Skip 1 -First 1)
                'patchVersion'      = ($parts | Select-Object -Skip 2 -First 1)
                'buildVersion'      = ($parts | Select-Object -Skip 3 -First 1)
                'preReleaseVersion' = ($Version.Split('-') | Select-Object -Last 1)
            }
            if ($Version -match '(?<head>\d+\.\d+(?:\.\d+)?)(?<tail>.*)') {
                $vars['matchHead'] = $Matches['head']
                $vars['matchTail'] = $Matches['tail']
            }
            $s = $Template
            # 長い名前から潰す。'$version' を先に消すと '$versionXxx' 形の
            # 置換子が食われる
            foreach ($k in ($vars.Keys | Sort-Object { $_.Length } -Descending)) {
                $v = if ($null -eq $vars[$k]) { '' } else { [string]$vars[$k] }
                $s = $s.Replace('$' + $k, $v)
            }
            $s
        }

        # checkver の名前付きキャプチャ($matchFoo)は version だけからは組み立て
        # られない。展開できなくても manifest の不備ではないので取り除いて見る
        $script:DropCustomMatches = { param([string]$Text) $Text -replace '\$match[A-Z]\w*', '' }

        # 各 manifest の autoupdate から、version を埋めて使われるテンプレートを
        # 場所つきで拾う。hash の regex などは $basename や $sha256 を正当に含む
        # ので対象にしない
        $script:AutoupdateTemplates = {
            param($Json)
            $au = $Json.autoupdate
            $found = @()
            foreach ($prop in 'url', 'extract_dir') {
                if ($au.$prop) {
                    $found += [pscustomobject]@{ Where = "autoupdate.$prop"; Text = ($au.$prop -join ' ') }
                }
                if ($au.architecture) {
                    foreach ($a in @($au.architecture.PSObject.Properties.Name)) {
                        if ($au.architecture.$a.$prop) {
                            $found += [pscustomobject]@{ Where = "autoupdate.architecture.$a.$prop"; Text = ($au.architecture.$a.$prop -join ' ') }
                        }
                    }
                }
            }
            $found
        }
    }

    # shovel の PR Validator は変更された manifest について Description と License を
    # 検査する。フォント manifest の必須キー検査はフォント以外を除外しているので、
    # tclock-win10 / umaumachecker / umaumacruise の 3 件が未記入のまま残っていた。
    # 除外リストの外側に置いて、bucket に増える manifest すべてを網に掛ける
    It '<_.BaseName> に description がある' -ForEach $script:AllManifestFiles {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $j.description | Should -Not -BeNullOrEmpty
    }

    It '<_.BaseName> に license がある' -ForEach $script:AllManifestFiles {
        # license は文字列(SPDX 識別子)でも { identifier, url } のオブジェクトでもよい。
        # オブジェクト形式で identifier が空だと Should -Not -BeNullOrEmpty は
        # 通ってしまうので、識別子そのものを取り出して見る
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $lic = $j.license
        $id = if ($lic -is [string]) { $lic } else { $lic.identifier }
        $id | Should -Not -BeNullOrEmpty
    }

    # BOM / CRLF はファイルの体裁なのでフォントかどうかに関係が無い。
    # フォント側の Describe に置いていたぶん、非フォントの 6 件は素通りしていた
    It '<_.BaseName> に BOM が付いていない' -ForEach $script:AllManifestFiles {
        $head = [IO.File]::ReadAllBytes($_.FullName)[0..2]
        ($head -join ',') | Should -Not -Be '239,187,191'
    }

    It '<_.BaseName> の改行が CRLF に揃っている' -ForEach $script:AllManifestFiles {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        $lf = 0; $crlf = 0
        for ($i = 0; $i -lt $b.Length; $i++) {
            if ($b[$i] -ne 10) { continue }
            if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } else { $lf++ }
        }
        $crlf | Should -BeGreaterThan 0
        $lf   | Should -Be 0
    }

    It '<_.BaseName> の URL が平文 http でない' -ForEach $script:AllManifestFiles {
        # 配布元が https を持っているのに http のまま書いてある manifest があった
        # (mery。実測: http は https へ 301 され、https で直接叩いても同じ
        # 6,096,429 バイトが返る)。
        #
        # 「hash を固定しているから平文でも安全」は install 経路にしか当てはまらない。
        # mery は autoupdate.hash を持たないので、checkver は落としたバイト列から
        # hash を計算して manifest へ書き込む(実測: `Downloading ... to compute
        # hashes!`)。Excavator はこれを毎時回して自動 commit するので、平文のままだと
        # 差し替えられた中身の hash がそのまま「正しい hash」として焼き付く。
        #
        # 生の本文を走査すると、XML の名前空間 URI(識別子であって取得先ではない)や
        # web.archive.org の URL に入れ子になった http まで拾ってしまう。とくに
        # installer.script は sync_scripts.py が 16 manifest へ配るので、1 本の
        # リンクで 16 件が同時に落ちて「名前空間を https にする」という誤った修正へ
        # 誘導される。取得先として使われるキーだけを見て、スキームの位置で判定する。
        #
        # 将来 https を持たない配布元が出てきたら、この判定を緩めるのではなく
        # 「その 1 件だけを明示的に除外する」形にすること
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

        $nodes = @($j, $j.autoupdate)
        foreach ($arch in $j.architecture, $j.autoupdate.architecture) {
            if ($arch) {
                foreach ($a in @($arch.PSObject.Properties.Name)) { $nodes += $arch.$a }
            }
        }

        $urls = @()
        foreach ($n in $nodes) {
            if (-not $n) { continue }
            foreach ($key in 'url', 'homepage') { if ($n.$key) { $urls += @($n.$key) } }
            if ($n.hash.url) { $urls += @($n.hash.url) }
        }
        # checkver も license も文字列のことがある('github' / 'MIT')。
        # 文字列に .url を引くと $null になるだけなので分岐は要らない
        foreach ($n in $j.checkver, $j.license) { if ($n.url) { $urls += @($n.url) } }

        # スキームは値の先頭。含まれているかで見ると
        # https://web.archive.org/web/2020id_/http://... のような正当な値を落とす。
        # (?i) はスキームが大文字小文字を区別しないため(HTTP:// も取得先は平文)
        $bad = @($urls | Where-Object { $_ -match '(?i)^http://' })
        ($bad -join ', ') | Should -BeNullOrEmpty
    }

    It '<_.BaseName> の autoupdate テンプレートを scoop が展開できる' -ForEach $script:AllManifestFiles {
        # scoop の substitute は素の文字列置換で、置換表の鍵は '$version' のような
        # 素のトークン。${version} 形式は一致せず、そのまま残る。tclock-win10 が
        # これで、2022 年に入った ${version}/${cleanVersion} が今の shovel では
        # 展開されない(実測: checkver -Update -ForceUpdate が
        # `.../download/${version}/TClock-Win10_${cleanVersion}_64bit.zip` を
        # そのまま叩いて 404 で失敗した)。checkver は成功したまま autoupdate だけが
        # 死ぬので、次のリリースが来るまで誰も気づかない
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($t in @(& $script:AutoupdateTemplates $j)) {
            $left = & $script:DropCustomMatches (& $script:ExpandVersion $t.Text $j.version)
            $left | Should -Not -Match '\$' -Because "$($t.Where) に scoop が展開できない置換子が残る"
        }
    }

    It '<_.BaseName> の extract_dir を autoupdate が維持できる' -ForEach $script:AllManifestFiles {
        # tclock-win10 は extract_dir を top-level に、autoupdate のテンプレートを
        # architecture.64bit に置いていた。scoop の autoupdate は同じ場所しか書き換え
        # ないので、version が 5.1.6.1 から 2 回上がっても extract_dir は 5161 のまま
        # 取り残された(実測: 5.4.1.1 の zip の最上位は TClock-Win10_5411_64bit)。
        # scoop は 7-Zip に -ir!<extract_dir>\* を渡すので、存在しないディレクトリでも
        # 「No files to process / Everything is Ok」で正常終了し、0 件を取り出す(実測)。
        # 壊れていることが install の失敗としてしか表に出てこないので静的に留める
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

        # scoop の Update-ManifestProperty と同じ順に更新先を決める。
        # top-level は「値もテンプレートも top-level にある」ときだけ、そうでなければ
        # architecture ごとに見て、テンプレートは arch 側 → top-level の順に探す
        $au = $j.autoupdate
        $targets = @()
        if ($j.extract_dir -and $au.extract_dir) {
            $targets += [pscustomobject]@{ Where = 'top-level'; Value = $j.extract_dir; Template = $au.extract_dir }
            # この枝に入ると scoop は top-level だけを書き換えて終わる。一方 install が
            # 読むのは arch_specific なので architecture 側があればそちらが勝つ。
            # 両方あると「更新される値」と「使われる値」が別物になり、また取り残される
            if ($j.architecture) {
                foreach ($a in @($j.architecture.PSObject.Properties.Name)) {
                    $j.architecture.$a.extract_dir | Should -BeNullOrEmpty -Because "top-level の extract_dir が autoupdate の更新先なのに architecture.$a が上書きしている。install で使われるのは architecture.$a 側で、そちらは更新されない"
                }
            }
        } elseif ($j.architecture) {
            foreach ($a in @($j.architecture.PSObject.Properties.Name)) {
                $tpl = if ($au.architecture.$a.extract_dir) { $au.architecture.$a.extract_dir } else { $au.extract_dir }
                if ($j.architecture.$a.extract_dir -and $tpl) {
                    $targets += [pscustomobject]@{ Where = "architecture.$a"; Value = $j.architecture.$a.extract_dir; Template = $tpl }
                }
            }
        }

        $hasTemplate = [bool]$au.extract_dir
        if (-not $hasTemplate -and $au.architecture) {
            foreach ($a in @($au.architecture.PSObject.Properties.Name)) {
                if ($au.architecture.$a.extract_dir) { $hasTemplate = $true }
            }
        }
        if ($hasTemplate) {
            $targets.Count | Should -BeGreaterThan 0 -Because 'autoupdate に extract_dir のテンプレートがあるのに、scoop が書き換える場所に extract_dir が無い。よそに置いた値は更新されず取り残される'
        }

        foreach ($t in $targets) {
            # extract_dir は url と 1 対 1 で並ぶ配列でもよい(schema は
            # stringOrArrayOfStrings、decompress.ps1 も @(extract_dir ...) して
            # url ごとに引いている)。素の文字列として扱うと配列がスペース連結の
            # 1 本に潰れ、正しい manifest を「version と食い違っている」という
            # 見当違いの理由で落とす。両辺を配列に揃えて要素ごとに見る
            $tpls = @($t.Template)
            $vals = @($t.Value)
            $vals.Count | Should -Be $tpls.Count -Because "$($t.Where) の extract_dir とテンプレートで件数が合わない"
            for ($i = 0; $i -lt $tpls.Count; $i++) {
                # 名前付きキャプチャが混じるものは version だけからは決まらないので
                # 突き合わせない。それ以外の展開漏れは上の It が落とす
                if ((& $script:DropCustomMatches $tpls[$i]) -ne $tpls[$i]) { continue }
                # 誤っているのは manifest 側なので、そちらを actual に置く
                $vals[$i] | Should -Be (& $script:ExpandVersion $tpls[$i] $j.version) -Because "$($t.Where) の extract_dir[$i] が現在の version と食い違っている"
            }
        }
    }
}

Describe 'manifest の静的検査' -Tag 'Static' {
    BeforeAll {
        $script:BucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
        $script:Fonts = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
            Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') } |
            ForEach-Object { [pscustomobject]@{ Name = $_.BaseName; Json = (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } })
        # BeforeDiscovery の $script:ManifestFiles は Discovery フェーズ限定で、
        # -ForEach では使えても Run フェーズの通常 It 本体からは見えない（実測: Count が 0 になる）。
        # ここで BeforeAll として同じフィルタを再設定し、Run フェーズでも参照できるようにする
        $script:ManifestFiles = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
            Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') })
    }

    It 'フォント manifest が 1 つ以上ある' {
        $script:Fonts.Count | Should -BeGreaterThan 0
    }

    It '<_.BaseName> に必須キーが揃っている' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in 'version', 'description', 'homepage', 'license', 'url', 'hash', 'checkver', 'autoupdate') {
            $j.PSObject.Properties.Name | Should -Contain $key
        }
    }

    It '<_.BaseName> の license は OFL-1.1' -ForEach $script:ManifestFiles {
        (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).license | Should -Be 'OFL-1.1'
    }

    It '<_.BaseName> の autoupdate.url に $version が入っている' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        ($j.autoupdate.url -join ' ') | Should -Match '\$version'
    }

    It '<_.BaseName> は extract_dir を持つなら autoupdate 側にも持つ' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'extract_dir') {
            $j.autoupdate.PSObject.Properties.Name | Should -Contain 'extract_dir'
        }
    }

    It 'installer.script が全 manifest で完全に同一' {
        $sets = $script:Fonts | ForEach-Object { ($_.Json.installer.script -join "`n") } | Select-Object -Unique
        $sets.Count | Should -Be 1
    }

    It 'pre_uninstall が全 manifest で完全に同一' {
        $sets = $script:Fonts | ForEach-Object { ($_.Json.pre_uninstall -join "`n") } | Select-Object -Unique
        $sets.Count | Should -Be 1
    }

    It 'uninstaller.script が全 manifest で完全に同一' {
        $sets = $script:Fonts | ForEach-Object { ($_.Json.uninstaller.script -join "`n") } | Select-Object -Unique
        $sets.Count | Should -Be 1
    }

    It '共通スクリプトのフィルタは 35 のみ（Discord を除外していない）' {
        $s = ($script:Fonts[0].Json.installer.script -join "`n")
        $s | Should -Match "notmatch '35'"
        $s | Should -Not -Match 'Discord'
    }

    It 'installer が global インストールを拒否する' {
        ($script:Fonts[0].Json.installer.script -join "`n") | Should -Match '\$global'
    }

    It 'installer がレジストリキー($regKey)を作成してから書き込む' {
        # 一度も per-user フォントを入れたことが無いプロファイルでは
        # HKCU\...\Fonts キー自体が存在せず、New-ItemProperty -Force はキーの
        # 作成まではしないため書き込みが失敗する(実測)。振る舞いテストには
        # scratch hive が要り割に合わないので、共有 installer に
        # キー作成が入っていることを静的に検査する
        $s = ($script:Fonts[0].Json.installer.script -join "`n")
        $s | Should -Match 'New-Item\s+-Path\s+\$regKey\s+-Force'
    }

    It 'sync_scripts.py を走らせても manifest が変化しない（冪等）' {
        # sync_scripts.py と scoop の checkhashes.ps1 が行末を潰し合い、
        # 実質的な変更が無いのに全 manifest へ差分が出続けた実績がある。
        # 片方を直しても、もう一方が将来変わればまた再発するのでテストで固定する
        $repo   = Split-Path $PSScriptRoot
        $before = @{}
        foreach ($f in $script:ManifestFiles) { $before[$f.FullName] = [IO.File]::ReadAllBytes($f.FullName) }

        & python3 (Join-Path $repo 'tests\tools\sync_scripts.py') *> $null
        $LASTEXITCODE | Should -Be 0

        $changed = @()
        foreach ($f in $script:ManifestFiles) {
            $now = [IO.File]::ReadAllBytes($f.FullName)
            if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$before[$f.FullName], [byte[]]$now)) {
                $changed += $f.Name
            }
        }
        ($changed -join ', ') | Should -BeNullOrEmpty
    }

    It 'installer と uninstaller が OS へフォントの増減を通知する' {
        # レジストリ登録とファイル配置だけでは、あとから起動したプロセスからも
        # DirectWrite にフォントが見えない(実測: plemoljp は HKCU に 48 件登録済み・
        # ファイルも実在の状態でファミリごと見えず、どのアプリからも使えなかった)。
        # 振る舞いは FontNotify.Tests.ps1 が検証する。ここでは将来のリファクタで
        # この呼び出しが黙って落ちないよう、静的にも留め金を掛けておく
        $j = $script:Fonts[0].Json
        $inst = ($j.installer.script -join "`n")
        $unin = ($j.uninstaller.script -join "`n")

        # 見るのは「$notifyFonts を呼んでいるか」。ここを間違えると歯が無くなる。
        # 素朴に 'AddFontResourceW' を探すと Add-Type の P/Invoke 宣言に当たり、
        # `[ScoopFont.Gdi]::AddFontResourceW(` にしても $notifyFonts の定義本体に
        # 当たる。どちらも両スクリプトが常に持っているので、呼び出しを全部消しても
        # 緑のままだった(実測。2 回とも意図的に壊して確かめて気づいた)。
        # 件数まで固定して、1 箇所でも欠けたら落ちるようにする
        $instCalls = @([regex]::Matches($inst, '&\s+\$notifyFonts\s+-(Add|Remove)'))
        $uninCalls = @([regex]::Matches($unin, '&\s+\$notifyFonts\s+-(Add|Remove)'))
        # installer: 上書き前の Remove / 正常系の Add / 巻き戻しの Remove と Add
        $instCalls.Count | Should -Be 4
        # uninstaller: 削除前の Remove / 復元後の Add
        $uninCalls.Count | Should -Be 2

        # 定義本体の方も残っていること
        $inst | Should -Match '\[ScoopFont\.GdiV\d+\]::AddFontResourceW\('
        $unin | Should -Match '\[ScoopFont\.GdiV\d+\]::RemoveFontResourceW\('
        # WM_FONTCHANGE = 0x1D。これを配らないと起動済みのアプリが一覧を作り直さない
        foreach ($s in $inst, $unin) {
            $s | Should -Match '\[ScoopFont\.GdiV\d+\]::SendMessageTimeout\('
            $s | Should -Match '0x1D'
        }
    }

    It '登録解除を while で回していない' {
        # 参照カウントはプロセスをまたいでセッション全体で共有される(実測: プロセス A が
        # 2 回 Add して終了した後、別プロセス B の RemoveFontResourceW が 2 回 true を
        # 返した)。false になるまで外すと、同じファイルを使っている第三者アプリの
        # 参照まで奪う。install 1 回につき Add 1 回・uninstall 1 回につき Remove 1 回で釣り合う
        foreach ($key in 'installer', 'uninstaller') {
            $s = ($script:Fonts[0].Json.$key.script -join "`n")
            $s | Should -Not -Match 'while\s*\([^)]*RemoveFontResourceW'
        }
    }

    It '外す対象を「自分が置いたファイル」に絞っている' {
        # 参照カウントはセッション共有なので、自分のものでない配置先まで外すと
        # 第三者アプリの参照を奪う。ハッシュ照合を撤回しても振る舞いテストでは
        # 落ちない(GDI の参照カウントを観測するテストが無い)ため静的に固定する
        foreach ($key in 'installer', 'uninstaller') {
            $s = ($script:Fonts[0].Json.$key.script -join "`n")
            $s | Should -Match '\$mine\s*=\s*@\('
            $s | Should -Match '&\s+\$isOurFile\s+\$_\.Dest\s+\$_\.Hash'
        }
    }

    It 'ハッシュ照合が例外を投げない形になっている' {
        # $ErrorActionPreference = 'Stop' の下では、ロックされたファイルへの
        # Get-FileHash は terminating error になる。巻き戻しや uninstall の
        # 入口でこれが飛ぶと、1 件のロックで後続が丸ごと止まる。
        #
        # スクリプト全体に対する `(?s)...try.*?Get-FileHash.*?catch` のような
        # 照合では歯が無い。遅延量指定子がブロックを飛び越えて、後方にある
        # 無関係な try/catch に届いてしまう(実測: try/catch を外しても緑だった)。
        # $isOurFile の本体だけを切り出してから見る
        foreach ($key in 'installer', 'uninstaller') {
            $lines = @($script:Fonts[0].Json.$key.script)
            $start = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^\$isOurFile\s*=\s*\{' })
            $start | Should -BeGreaterThan -1 -Because "$key に `$isOurFile の定義が無い"

            # 列 0 の閉じ括弧が本体の終わり。中の閉じ括弧は必ず字下げされている
            $end = -1
            for ($i = $start + 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -eq '}') { $end = $i; break }
            }
            $end | Should -BeGreaterThan $start -Because "$key の `$isOurFile の終わりが見つからない"

            $body = ($lines[$start..$end] -join "`n")
            $body | Should -Match 'Get-FileHash'
            # [^}]* で閉じ括弧を跨がせない。try の直下に Get-FileHash があること
            $body | Should -Match '(?s)try\s*\{[^}]*Get-FileHash'
            $body | Should -Match 'catch\s*\{'
        }
    }

    It '実際に外せた分だけを戻す（呼んだ回数で数えていない）' {
        # RemoveFontResourceW は参照が 0 になると false を返して飽和するのに、
        # AddFontResourceW は飽和しない。呼んだ回数で数えると、空振りした
        # Remove のぶんまで Add してしまい、触ってもいないファイルの参照が純増する。
        # その参照はセッションから二度と外せない
        foreach ($key in 'installer', 'uninstaller') {
            $s = ($script:Fonts[0].Json.$key.script -join "`n")
            # 返り値を捨てず、true のときだけ記録していること
            $s | Should -Match 'if \(\[ScoopFont\.GdiV\d+\]::RemoveFontResourceW\(\$p\)\)\s*\{\s*\[void\]\$removedOk\.Add\(\$p\)'
        }
        # installer の巻き戻しは「実際に外せた分」から戻す
        $inst = ($script:Fonts[0].Json.installer.script -join "`n")
        $inst | Should -Match 'foreach \(\$p in @\(\$removedOk\)\)'

        # uninstaller は、それに加えて「元から GDI 参照があったか」で絞る。
        # 外したのは install 時に自分が足した参照で、戻す先は復元された元ファイル。
        # 元ファイルを誰も参照していなかったなら戻してはいけない
        $unin = ($script:Fonts[0].Json.uninstaller.script -join "`n")
        $unin | Should -Not -Match '&\s+\$notifyFonts\s+-Add\s+@\(\$mine'
        $unin | Should -Match '\$hadRef\s+-and\s+\(\$removedOk -contains \$_\.Dest\)'

        # 記録に HadGdiRef が「無い」場合を false と同一視しない。
        # ConvertFrom-Json は存在しないプロパティを $null にするので、この項目を
        # 書いていなかった版の記録を読むと区別が付かず、第三者の参照を消す
        $unin | Should -Match "PSObject\.Properties\.Name -contains 'HadGdiRef'"
    }

    It 'installer が変更のあとに Add してからブロードキャストする' {
        # 件数だけ固定していると、正常系の -Add を -Remove に書き換えても
        # 静的には気づけない(実測)。ループより後ろにあることまで見る
        $lines = @($script:Fonts[0].Json.installer.script)
        $loopAt = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^\s*foreach \(\$e in \$plan\)' })
        $addAt  = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '&\s+\$notifyFonts\s+-Add\s+@\(\$plan.*-Broadcast' })
        $loopAt | Should -BeGreaterThan -1
        $addAt  | Should -BeGreaterThan $loopAt
    }

    It 'Test-Path が常に -LiteralPath 付きで呼ばれている' {
        # 配置先はフォントのファイル名から組み立てる。Google の可変フォント配布
        # (NotoSansJP[wght].ttf 形式)のように角括弧が入ると、素の Test-Path は
        # ワイルドカードとして解釈して誤判定する。とくに退避の存在判定を誤ると、
        # 既存の退避(第三者の元ファイル)を今の配置先で上書きしてしまう。
        # 現在の 228 ファイルに角括弧は無いので、これは潜在的な備え
        foreach ($key in 'installer', 'pre_uninstall', 'uninstaller') {
            $block = if ($key -eq 'pre_uninstall') { $script:Fonts[0].Json.$key }
                     else { $script:Fonts[0].Json.$key.script }
            # 「ダッシュで始まっていれば OK」では -Path が素通りする。
            # -Path はワイルドカードを解釈するので、このテストが防ぎたい失敗が
            # そのまま起きる(実測: -LiteralPath を -Path に変えても緑だった)。
            # ホワイトリストにして -LiteralPath だけを許す
            $bad = @($block | Where-Object {
                $_ -notmatch '^\s*#' -and $_ -match 'Test-Path(?!\s+-LiteralPath\b)'
            })
            ($bad -join ' / ') | Should -BeNullOrEmpty -Because "$key に -LiteralPath 無しの Test-Path がある"
        }
    }

    It 'P/Invoke の型名に版番号が付いている' {
        # scoop update は同一プロセスで旧版 uninstaller → 新版 installer を走らせる。
        # 型名が同じだと新版の Add-Type が飛ばされ、新版のコードが旧版の定義で動く
        foreach ($key in 'installer', 'uninstaller') {
            $s = ($script:Fonts[0].Json.$key.script -join "`n")
            $s | Should -Match "Add-Type -Namespace 'ScoopFont' -Name 'GdiV\d+'"
            $s | Should -Not -Match "\[ScoopFont\.Gdi\]::"
        }
    }

    It 'installer が上書きの前に登録を外し、元の参照有無を記録する' {
        # 参照カウントが 0 でないパスにファイルを被せても GDI は読み直さず、
        # 古い中身を配り続ける(実測)。正常系にも Remove が要る。
        #
        # 「$notifyFonts -Remove」の存在だけを見ると、渡す配列を空にする変異を
        # 見逃す(実測: 変数を空配列に潰しても緑だった)。実在する配置先だけを
        # 対象にしていること、true が返ったかを記録していること、
        # そして変更に入る前であることまで含めて見る
        $lines = @($script:Fonts[0].Json.installer.script)
        $find = {
            param([string]$Pattern)
            [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match $Pattern })
        }
        $removeAt   = & $find '&\s+\$notifyFonts\s+-Remove\s+@\(\$e\.Dest\)'
        $gateAt     = & $find 'if \(-not \(Test-Path -LiteralPath \$e\.Dest -PathType Leaf\)\) \{ continue \}'
        $recordAt   = & $find '\$e\.HadGdiRef\s*=\s*\(\$removedOk\.Count\s+-gt\s+\$before\)'
        $mutatingAt = & $find "\`$e\.Phase = 'mutating'"

        $removeAt   | Should -BeGreaterThan -1 -Because '上書き前の Remove が無い'
        $gateAt     | Should -BeGreaterThan -1 -Because '対象が「今そこにファイルが在るか」で絞られていない'
        $recordAt   | Should -BeGreaterThan -1 -Because '元から参照があったかを記録していない'
        $mutatingAt | Should -BeGreaterThan -1

        $gateAt   | Should -BeLessThan $removeAt
        $removeAt | Should -BeLessThan $recordAt
        $recordAt | Should -BeLessThan $mutatingAt -Because '記録は変更に入る前に済ませる'
    }

    It 'uninstaller はファイルを消す前に GDI の登録を外す' {
        # 消した後に RemoveFontResourceW を呼んでもパスを解決できず false が
        # 返るだけで、セッションのフォントテーブルに残り続ける(実測: 削除後は
        # 0 回 true、削除前なら 3 回 true を返して一覧から消えた)。
        # 順序が入れ替わると FontNotify.Tests.ps1 の 3 件目で落ちるが、
        # あちらは実機を書き換えるスイートなので静的にも留め金を掛けておく
        $lines = @($script:Fonts[0].Json.uninstaller.script)
        $removeAt = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '\$notifyFonts\s+-Remove' })
        $loopAt   = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^foreach \(\$e in \$entries\)' })
        $removeAt | Should -BeGreaterThan -1
        $loopAt   | Should -BeGreaterThan -1
        $removeAt | Should -BeLessThan $loopAt
    }

    It '共通スクリプトが PowerShell として構文解析できる' {
        # sync_scripts.py は行を機械的に配るだけで中身を検査しない。
        # 壊れたスクリプトを配っても manifest としては妥当な JSON になるため、
        # 構文エラーは scoop install を実行するまで表に出てこない
        $j = $script:Fonts[0].Json
        foreach ($block in @{ n = 'installer'; s = $j.installer.script },
                           @{ n = 'pre_uninstall'; s = $j.pre_uninstall },
                           @{ n = 'uninstaller'; s = $j.uninstaller.script }) {
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput(
                ($block.s -join "`n"), [ref]$null, [ref]$errs)
            @($errs | ForEach-Object { "$($block.n): $($_.Message)" }) -join '; ' |
                Should -BeNullOrEmpty
        }
    }

    It '通知の失敗が install/uninstall を巻き添えにしない' {
        # フォント自体は既に置かれている。通知できないことを理由に throw すると
        # 成功した変更まで巻き戻すことになり、実害の方が大きい。
        # $notifyFonts の本体と Add-Type の両方が try/catch の中にあること
        foreach ($key in 'installer', 'uninstaller') {
            $s = ($script:Fonts[0].Json.$key.script -join "`n")
            # Add-Type は環境によっては失敗しうるので、それ自体を包んである
            $s | Should -Match '(?s)try\s*\{[^}]*Add-Type\s+-Namespace\s+''ScoopFont'''
            # 通知本体も包んである。catch 側は Write-Host で警告するだけ
            $s | Should -Match '(?s)\$notifyFonts\s*=\s*\{.*?try\s*\{.*?\}\s*catch\s*\{[^}]*Write-Host'
        }
    }

    It '共通スクリプトの原本に BOM が付いている' -ForEach @('installer', 'pre_uninstall', 'uninstaller') {
        # PowerShell 5.1 は BOM 無し UTF-8 を cp932 と誤解釈する。原本の BOM が
        # 落ちると日本語コメントが化けたまま 16 manifest 全部へ伝播する。
        # sync_scripts.py は utf-8-sig で読む(BOM 無しでも通る)ので気づけず、
        # 新設の構文解析テストもコメントの化けは検出しない
        $path = Join-Path (Split-Path $PSScriptRoot) "scripts\$_.ps1"
        $path | Should -Exist
        $head = [IO.File]::ReadAllBytes($path)[0..2]
        ($head -join ',') | Should -Be '239,187,191'
    }

    It '共通スクリプトが読み取り専用の自動変数へ代入していない' {
        # $pid への代入で全 manifest が動かなくなった実績がある。
        # 関数スコープの中でも Cannot overwrite variable PID で落ちる
        $reserved = 'pid', 'host', 'error', 'true', 'false', 'null', 'pshome', 'shellid', 'executioncontext'
        $j = $script:Fonts[0].Json
        # コメント行は除く。「$true = 自分のファイル」のような説明書きに反応して
        # 誤検出する(実測)。コメントは代入しないので、除いても検出力は落ちない
        $all = (@($j.installer.script) + @($j.pre_uninstall) + @($j.uninstaller.script) |
                Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $bad = @($reserved | Where-Object { $all -match ('\$' + $_ + '\s*=[^=]') })
        ($bad -join ', ') | Should -BeNullOrEmpty
    }
}
