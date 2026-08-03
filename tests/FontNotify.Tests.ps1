BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ScoopApp.psm1') -Force
    $script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
    $script:Repo     = Split-Path $PSScriptRoot
    $script:Manifest = Join-Path $script:Repo 'bucket\bizin-gothic-discord.json'
    $script:App      = 'bizin-gothic-discord'
    # 検証に使うファミリは 2 つの条件を満たす必要がある。
    #   1. HKLM に同名の登録が無いこと。あると install の有無に関わらず「見える」になり、
    #      このスイート全体が無意味になる(実測: HackGen・BIZTER・NOTONOTO・BIZ UD 系・
    #      UDEV Gothic 系は C:\Windows\Fonts にも入っており、この条件を満たさない)
    #   2. ファイル数が少ないこと。install/uninstall を 2 往復するので
    # Bizin Gothic Discord は 2 ファイルで HKLM にも無く、両方を満たす
    $script:Family = 'Bizin Gothic Discord'

    # DirectWrite のフォント一覧はプロセス内でキャッシュされるため、必ず新しい
    # プロセスに聞く。同一プロセスで問い合わせると install 前後で同じ答えしか
    # 返らず、テストが常に緑(または常に赤)になって検証にならない
    $script:IsFamilyVisible = {
        param([string]$Family)
        $probe = @"
Add-Type -AssemblyName PresentationCore
if ([System.Windows.Media.Fonts]::SystemFontFamilies | Where-Object { `$_.Source -eq '$Family' }) { 'VISIBLE' } else { 'MISSING' }
"@
        (& powershell.exe -NoProfile -Command $probe | Out-String).Trim()
    }

    $script:TrueBefore   = Get-FontEnvSnapshot
    $script:WasInstalled = Test-AppInstalled -App $script:App -ScoopRoot $script:ScoopRoot
    # 入れ直すときの出どころを uninstall の前に控える。控えずに
    # $script:Manifest から入れ直すと install.json にリポジトリのパスが焼き付き、
    # scoop update が bucket ではなくそのファイルを見続けることになる
    $script:OrigSource  = Get-AppInstallSource    -App $script:App -ScoopRoot $script:ScoopRoot
    $script:OrigVersion = Get-AppInstalledVersion -App $script:App -ScoopRoot $script:ScoopRoot
    scoop uninstall $script:App 2>&1 | Out-Null
}

AfterAll {
    scoop uninstall $script:App 2>&1 | Out-Null
    if ($script:WasInstalled) {
        Restore-AppInstall -App $script:App -ScoopRoot $script:ScoopRoot `
            -OriginalSource $script:OrigSource -OriginalVersion $script:OrigVersion `
            -Fallback $script:Manifest
    }
    Assert-FontEnvRestored -Before $script:TrueBefore
}

Describe 'install した直後にアプリからフォントが見えること' {
    # レジストリ登録とファイル配置だけでは、あとから起動したプロセスからも
    # DirectWrite にフォントが見えない。実測では plemoljp が HKCU に 48 件
    # 登録済み・ファイルも実在という状態でファミリごと見えず、どのアプリからも
    # 使えなかった。installer/uninstaller の AddFontResourceW・
    # RemoveFontResourceW と WM_FONTCHANGE のブロードキャストがこれを直す

    It '前提: 未インストールのとき見えない' {
        # ここが VISIBLE だと以下 2 件は install の有無と無関係に通ってしまう。
        # HKLM に同名登録があるファミリへ差し替えた場合にここで気づけるようにしてある。
        #
        # ただし「見えたまま」には、この検証では手が出せない原因が 2 つある。
        #   1. ログオン時に Windows が HKCU のフォントをセッションへ登録する。
        #      その参照は install が足す 1 つとは別なので、uninstall の Remove を
        #      1 回してもセッションからは消えない(実測: 再起動後、参照が
        #      logon の 1 + install の 1 = 2 になり、uninstall 後も 1 残った)
        #   2. 参照先を消した後の登録は RemoveFontResourceW では外せない
        # どちらも再ログオンするまで解消しないので、失敗ではなく skip にする。
        # 緑と偽らず、理由を出して人が判断できるようにする
        $seen = & $script:IsFamilyVisible $script:Family
        if ($seen -eq 'VISIBLE') {
            Set-ItResult -Skipped -Because ("$script:Family が未インストールでもセッションに残っている。" +
                'ログオン時に登録されたか、参照先を消した後の登録が外せていない。再ログオン後に再実行すること')
        }
        $seen | Should -Be 'MISSING'
    }

    It 'install 後、新しいプロセスから見える' {
        # install の成否を捨てると、install 自体がこけたときに
        # 「フォントが見えない」という誤った症状で報告されてしまう。
        # 先に install の成立を確かめてから見え方を見る
        $out = (scoop install $script:Manifest 2>&1 | Out-String)
        (scoop list $script:App 6>$null | Out-String) |
            Should -Match ([regex]::Escape($script:App)) -Because "install が成立していない: $out"

        # ここが MISSING のとき、疑うべきは installer だけではない。
        # セッションのフォントテーブルは起動時に載った登録を保持し続け、
        # 参照先のファイルを消してもその登録は残る(RemoveFontResourceW は
        # パスが解決できないと外せないため)。machine-wide のフォントを
        # 片付けた直後などは、死んだ登録が per-user 側を隠してこの検証が落ちる。
        # その場合は再ログオンで解消する
        (& $script:IsFamilyVisible $script:Family) |
            Should -Be 'VISIBLE' -Because 'ファイルとレジストリが正しくても、セッションに死んだ登録が残っていると見えない。再ログオン後に再実行して切り分けること'
    }

    It 'uninstall 後、新しいプロセスから見えなくなる' {
        # 直前の It が落ちていると、この It は install されていない状態で走って
        # 素通りする。前提が揃っているかを自分で確かめてから進む
        (scoop list $script:App 6>$null | Out-String) |
            Should -Match ([regex]::Escape($script:App)) -Because '前の It が失敗している。この検証は成立しない'

        $out = (scoop uninstall $script:App 2>&1 | Out-String)
        (scoop list $script:App 6>$null | Out-String) |
            Should -Not -Match ([regex]::Escape($script:App)) -Because "uninstall が成立していない: $out"

        # ログオン時の登録が残っているセッションでは、uninstall の Remove 1 回では
        # 参照が 0 に落ちず見えたままになる。1 件目と同じ理由なので同じ扱いにする
        $seen = & $script:IsFamilyVisible $script:Family
        if ($seen -eq 'VISIBLE') {
            Set-ItResult -Skipped -Because ('ログオン時の登録が残っているため uninstall の Remove 1 回では消えない。' +
                '再ログオン後に再実行すること')
        }
        $seen | Should -Be 'MISSING'
    }
}
