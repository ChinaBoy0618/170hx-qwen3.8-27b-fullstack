#!/usr/bin/env bash
# 760T 运维备份 · 精选文件 → git 仓库（Windows 侧 git pull 拉走）
# db 快照另行落 /mnt/data/ops-dbs（不进 git，Windows 侧 scp 单拉）。
set -uo pipefail

REPO=/mnt/data/ops-backup
DBDIR=/mnt/data/ops-dbs
SRC=/mnt/data/sglang-qwen38
FRP=/mnt/nvme1/frp
HOMEBIN=/home/i/bin
DB=/mnt/data/new-api/data/one-api.db
TS=$(date +%Y%m%d-%H%M%S)
DAYS_KEEP=30

mkdir -p "$REPO"/{sglang-qwen38,frp,home-bin}
mkdir -p "$DBDIR"

### 1) 权威脚本 + 回滚锚（launch-int8*.sh / run-router*.sh 及其全部 .bak-*）
for f in "$SRC"/launch-int8*.sh "$SRC"/run-router*.sh; do
  [ -f "$f" ] && cp -a "$f" "$REPO/sglang-qwen38/"
done
# 评测/运维脚本 + 报表器
for f in "$SRC"/frt_report.py "$SRC"/quant_ab_eval.py "$SRC"/e1_multiturn.py \
         "$SRC"/canary-bench.py "$SRC"/canary-selfcheck.py "$SRC"/repro_bench.py \
         "$SRC"/ttl_bench.py "$SRC"/bench_w8mtp_0903.py "$SRC"/760_unlimited_key.py; do
  [ -f "$f" ] && cp -a "$f" "$REPO/sglang-qwen38/"
done

### 2) 本地补丁子目录（小、不可重建）
for d in ttl-patches keepalive-patch verify-budget-patch pp2-patch hicache-cmd-backup yarn512k; do
  if [ -d "$SRC/$d" ]; then
    mkdir -p "$REPO/sglang-qwen38/$d"
    cp -a "$SRC/$d/." "$REPO/sglang-qwen38/$d/" 2>/dev/null || true
  fi
done

### 3) frpc 真身（token 脱敏）+ 备份链
cp -a "$FRP"/frpc.ini "$REPO/frp/frpc.ini.real" 2>/dev/null || true
# 脱敏版入 git：把 token 换占位
if [ -f "$REPO/frp/frpc.ini.real" ]; then
  sed -E 's/^(token[[:space:]]*=[[:space:]])[^[:space:]]*/\1<REDACTED>/; s/^(auth\.token[[:space:]]*=[[:space:]])[^[:space:]]*/\1<REDACTED>/' \
    "$REPO/frp/frpc.ini.real" > "$REPO/frp/frpc.ini"
  chmod 600 "$REPO/frp/frpc.ini.real"
fi
for f in "$FRP"/frpc.ini.bak*; do
  [ -f "$f" ] && cp -a "$f" "$REPO/frp/"
done
# 死文件 toml 也留档（便于追溯），同样脱敏
cp -a /home/i/frpc/frpc.toml "$REPO/frp/frpc.toml.stale" 2>/dev/null || true
[ -f "$REPO/frp/frpc.toml.stale" ] && sed -i -E 's/(auth\.token[[:space:]]*=[[:space:]])[^[:space:]]*/\1<REDACTED>/' "$REPO/frp/frpc.toml.stale"

### 4) home/bin 运维脚本（在 /home/i/ 下，非 bin/）
cp -a "$HOMEBIN"/. "$REPO/home-bin/" 2>/dev/null || true

### 5) one-api.db 每日快照（python sqlite3 .backup 活库安全导出）→ ops-dbs（不进 git）+ 本地滚动 30 份
if [ -f "$DB" ]; then
  python3 - "$DB" "$DBDIR/one-api-$TS.db" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
c = sqlite3.connect(dst); s = sqlite3.connect(src)
with c: s.backup(c)
PY
  # 滚动清理：只保留最近 $DAYS_KEEP 份
  ls -1t "$DBDIR"/one-api-*.db 2>/dev/null | tail -n +$((DAYS_KEEP+1)) | xargs -r rm -f
fi

### 6) MANIFEST（每次重生成，列出本次收录）
{
  echo "# 760T ops-backup manifest · $TS"
  echo "# 收录：权威脚本+回滚锚 / 补丁树 / frpc(脱敏) / home-bin"
  echo "# db 快照在 /mnt/data/ops-dbs（不进 git，scp 单拉）"
  echo "# 排除：build/ .whl sglang-src* v0518-tree gw-build logs router.log *.log *.jsonl ab_results"
  find "$REPO" -type f -not -path "*/.git/*" | sed "s#$REPO/##" | sort
} > "$REPO/MANIFEST.txt"

### 7) git commit（Windows 侧 git pull 拉走）
cd "$REPO"
if [ ! -d .git ]; then git init -q .; fi
git config user.name  "760-ops-backup"
git config user.email "ops@760.local"
git add -A
if [ -n "$(git status --porcelain)" ]; then
  git commit -q -m "ops-backup $TS"
  echo "COMMITTED $(git rev-parse --short HEAD) $(git status --porcelain | wc -l) staged-clean"
else
  echo "NO-CHANGE (nothing new since last run)"
fi
