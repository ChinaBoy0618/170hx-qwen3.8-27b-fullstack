#!/bin/bash
# new-api channel base_url 切换唯一权威（09-10 部署调整：new-api 直连 smg）
# 启停 = 不在此脚本。new-api 容器永远不重启（channels 行 live 生效，SIGHUP 杀进程）
# 用法：
#   bash newapi-channels.sh set   <base_url>  # 改 channel#1/#2 base_url + 备份 + 验证
#   bash newapi-channels.sh revert             # 回滚到最近一次 .bak-channels-* 备份
#   bash newapi-channels.sh show               # 列出当前 channel#1/#2 + abilities
set -eu

DB_HOST_DIR=/mnt/data/new-api/data
DB_FILE=$DB_HOST_DIR/one-api.db
DB_BAK_DIR=/mnt/data/new-api/data
BACKUP="$DB_BAK_DIR/one-api.db.bak-channels-$(date +%Y%m%d-%H%M%S)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

# 目标 base_url 通过环境变量 BASE_URL 传给 node，避免 process.argv 偏移坑
TARGET_BASE_URL="${BASE_URL-}"

TMPJS=$(mktemp /tmp/_chanupdate.XXXXXX.js)
trap 'rm -f "$TMPJS"' EXIT

write_update_js() {
  cat > "$TMPJS" <<'EOF'
const {DatabaseSync} = require('node:sqlite');
const target = process.env.BASE_URL;
if (!target) { console.error('BASE_URL env not set'); process.exit(2); }
const db = new DatabaseSync('/data/one-api.db');
db.exec('BEGIN IMMEDIATE');
const r = db.prepare("UPDATE channels SET base_url=? WHERE id IN (1,2)").run(target);
console.log('rows_changed=' + r.changes);
db.exec('COMMIT');
for (const row of db.prepare('SELECT id,base_url FROM channels WHERE id IN (1,2)').all()) console.log(JSON.stringify(row));
EOF
}

write_show_js() {
  cat > "$TMPJS" <<'EOF'
const {DatabaseSync} = require('node:sqlite');
const db = new DatabaseSync('/data/one-api.db');
console.log('---channels #1/#2---');
for (const row of db.prepare('SELECT id,name,type,base_url,status,weight,priority,"group" FROM channels WHERE id IN (1,2)').all()) console.log(JSON.stringify(row));
console.log('---abilities ch1/2---');
for (const row of db.prepare('SELECT * FROM abilities WHERE channel_id IN (1,2)').all()) console.log(JSON.stringify(row));
EOF
}

write_verify_js() {
  cat > "$TMPJS" <<'EOF'
const {DatabaseSync} = require('node:sqlite');
const db = new DatabaseSync('/data/one-api.db');
for (const row of db.prepare('SELECT id,base_url FROM channels WHERE id IN (1,2)').all()) console.log(JSON.stringify(row));
EOF
}

run_sql_js() {
  docker run --rm \
    -e BASE_URL="$TARGET_BASE_URL" \
    -v "$DB_HOST_DIR:/data" \
    -v "$TMPJS:/tmp/_chan.js" \
    node:22-slim node --no-warnings --experimental-sqlite /tmp/_chan.js
}

do_backup() {
  local src="$1" dst="$2"
  [[ -e "$dst" ]] && { red "已存在 $dst，不覆盖"; exit 1; }
  cp -p "$src" "$dst"
  echo "备份 $src -> $dst"
}

do_set() {
  TARGET_BASE_URL="${2-}"
  [[ -n "$TARGET_BASE_URL" ]] || { red "set 需要 base_url 参数"; exit 1; }
  [[ "$TARGET_BASE_URL" =~ ^https?://[^:/]+:[0-9]+/?$ ]] || { red "base_url 格式非法: $TARGET_BASE_URL（要 http://host:port）"; exit 1; }

  yellow "[1/4] 备份当前 db -> $BACKUP"
  do_backup "$DB_FILE" "$BACKUP"

  yellow "[2/4] 写 UPDATE 脚本 + 在 node:22-slim 容器内事务执行（BASE_URL=$TARGET_BASE_URL）"
  write_update_js
  run_sql_js

  yellow "[3/4] 只读复核（从宿主路径直读）"
  write_verify_js
  run_sql_js

  yellow "[4/4] 用 owner-unlimited token 直打 new-api 验证（10s 超时）"
  local token="${NEWAPI_OWNER_TOKEN:?need to export NEWAPI_OWNER_TOKEN (see .env.example)}"
  curl -s -o /tmp/_na_check -w 'newapi_messages_status=%{http_code} time=%{time_total}\n' \
    --max-time 10 -X POST http://127.0.0.1:3001/v1/messages \
    -H "x-api-key: $token" \
    -H 'content-type: application/json' \
    -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"qwen3.8","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}'
  head -c 300 /tmp/_na_check; echo
}

do_revert() {
  yellow "[1/3] 找最近一个 .bak-channels-* 备份"
  local latest
  latest=$(ls -1t "$DB_BAK_DIR"/one-api.db.bak-channels-* 2>/dev/null | head -1 || true)
  [[ -n "$latest" ]] || { red "未找到 .bak-channels-* 备份"; exit 1; }
  echo "将用 $latest 回滚"

  yellow "[2/3] 备份当前 db 再用 cp 覆盖"
  do_backup "$DB_FILE" "$DB_BAK_DIR/one-api.db.bak-channels-pre-revert-$(date +%Y%m%d-%H%M%S)"
  cp -p "$latest" "$DB_FILE"

  yellow "[3/3] 只读复核"
  write_verify_js
  run_sql_js
}

do_show() {
  write_show_js
  run_sql_js
}

case "${1-show}" in
  set)    do_set "$@" ;;
  revert) do_revert ;;
  show)   do_show ;;
  *) red "用法: $0 {set <base_url>|revert|show}"; exit 1 ;;
esac
