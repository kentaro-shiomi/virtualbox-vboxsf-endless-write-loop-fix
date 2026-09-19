# vboxsf-fix（日本語の要約）

最終更新：2026-09-20 ／ 上流への報告：済（査読待ち）

VirtualBox の共有フォルダ（`vboxsf`）に、**まだ読み込まれていないメモリのページ**から
書き込むと、カーネルの中で書き込み処理が無限ループします。中身がゼロのファイルが
増え続けてディスクが埋まり、書き込んだプロセスは `kill -9` でしか止まりません。

詳しい解説は日本語の記事にあります → https://techhowto.blog/posts/virtualbox-vboxsf-endless-write-loop-bug

## 症状の見分け方

- 共有フォルダのファイルが、数バイトのはずなのに中身ゼロで増え続ける
- `dmesg` に `iov_iter_revert` を含む警告が大量に出る
- `syslog`、`kern.log`、journal が数GB に膨らむ

```sh
findmnt -t vboxsf
modinfo -n vboxsf     # kernel/fs/vboxsf/... なら対象
dmesg | grep -c iov_iter_revert
```

## 原因と修正

`fs/vboxsf/file.c` の `vboxsf_write_end()` が、コピーできなかった分まで「書けた」と
返しているため、呼び出し側がページの読み込みをやり直さず、位置だけ進めて無限に
繰り返します。`patches/` の 2 行の修正で直ります。

## 導入

必要なもの：`dkms`、`gcc`、`make`、`curl`、`patch`、実行中のカーネルのヘッダー。
Secure Boot が有効な環境では、署名がないため読み込めません。

```sh
sudo ./scripts/install.sh
```

アンインストールは `sudo ./scripts/uninstall.sh` です。

インストール時に `fs/vboxsf` のソースを GitHub から取得します。取得が集中していると
一時的に失敗することがあるので（HTTP 429）、その場合は数分おいて実行し直してください。
取得先は GitHub と git.kernel.org の2つを自動で試し、数回まで再試行します。

カーネル更新でビルドに失敗したときに気付けるよう、修正版でなければ共有フォルダを
マウントしない仕組み（`tools/vboxsf-fix-check`）も入ります。使い方は英語版の README を
参照してください。

## 上流への報告

2026-09-19 に vboxsf の保守担当と linux-fsdevel にパッチを送付し、査読待ちです。

- カーネルのメーリングリストのスレッド：英語版 README の [Upstream status](README.md#upstream-status) を参照
- Ubuntu（Launchpad）： https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2167772
