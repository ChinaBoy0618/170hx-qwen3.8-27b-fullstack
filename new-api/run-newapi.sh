#!/bin/bash
# new-api (one-api) 容器版（09-10 起 host 网络）
# 镜像 new-api:fixtoolidx-0831 (sha256:5e898637e63cd853c62ab8089c9cc6165fd7af28340e8bc2d4a47636cd9bad28)
# 网络 host（让容器内 127.0.0.1 直达宿主 smg :30010）
# 数据卷 /mnt/data/new-api/data -> /data (sqlite one-api.db)
# env: PORT=3001 HOST=0.0.0.0
# restart: unless-stopped
# 用法: bash run-newapi.sh [start|stop|restart|status]
#
# 历史: 09-10 之前 new-api 在 bridge 网络，channel base_url 指 172.17.0.1:30010 因 docker0
# hairpin NAT 对 host-network 容器端口规则不全导致 i/o timeout；改为 host 网络直接 dial
# 127.0.0.1:30010 解决。回滚 = NETWORK=bridge + 端口转发 + base_url 写 172.17.0.1:30010
# （见 newapi-channels.sh revert）
#
# 09-10 教训: 不要现场拼 docker run。改启动参数必须改这个脚本然后跑 start。
set -uo pipefail

NAME=${NAME:-new-api}
IMG=${IMG:-sha256:5e898637e63cd853c62ab8089c9cc6165fd7af28340e8bc2d4a47636cd9bad28}
NETWORK=${NETWORK:-host}
PORT=${PORT:-3001}
HOST=${HOST:-0.0.0.0}
DATA_VOL=${DATA_VOL:-/mnt/data/new-api/data}
DATA_MOUNT=${DATA_MOUNT:-/data}

# 锁: stop+start 防并发
LOCK_FILE=/tmp/${NAME}.lock
acquire_lock() {
  if [[ -e "$LOCK_FILE" ]]; then
    local holder
    holder=$(cat "$LOCK_FILE" 2>/dev/null || echo '?')
    if kill -0 "$holder" 2>/dev/null; then
      echo "ERROR: another run-newapi.sh is running (pid=$holder)" >&2
      exit 1
    fi
  fi
  echo $$ > "$LOCK_FILE"
}
release_lock() { rm -f "$LOCK_FILE"; }

is_running() {
  [[ "$(docker inspect "$NAME" --format '{{.State.Status}}' 2>/dev/null)" == "running" ]]
}
container_pid() {
  docker inspect "$NAME" --format '{{.State.Pid}}' 2>/dev/null
}
has_port_conflict() {
  if ss -lntH "sport = :$PORT" 2>/dev/null | grep -q LISTEN; then
    local owners
    owners=$(ss -lntpH "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | sort -u)
    for p in $owners; do
      local pid=${p#pid=}
      local my_pid
      my_pid=$(container_pid 2>/dev/null || echo 0)
      [[ "$pid" != "$my_pid" ]] && echo "$pid"
    done
  fi
}

do_start() {
  acquire_lock; trap release_lock EXIT
  if is_running; then
    echo "$NAME already running (pid=$(container_pid))"
    return 0
  fi
  if ! docker inspect "$NAME" --format '{{.Id}}' >/dev/null 2>&1; then
    echo "ERROR: container $NAME not present. re-create:" >&2
    echo "  docker run -d --name $NAME --network $NETWORK --restart unless-stopped \\" >&2
    echo "    -e PORT=$PORT -e HOST=$HOST -v $DATA_VOL:$DATA_MOUNT \\" >&2
    echo "    $IMG" >&2
    return 1
  fi
  local conflicts
  conflicts=$(has_port_conflict)
  if [[ -n "$conflicts" ]]; then
    echo "ERROR: port $PORT already in use by host pid(s): $conflicts" >&2
    echo "       这是 bridge 容器改 host 之前的旧 docker-proxy 转发。运行:" >&2
    echo "         docker rm -f <旧容器名>" >&2
    echo "       再重跑 start" >&2
    return 1
  fi

  echo "[start] $NAME (image=$IMG net=$NETWORK port=$PORT vol=$DATA_VOL)"
  docker start "$NAME"
  sleep 2
  if is_running; then
    echo "[start] OK pid=$(container_pid)"
  else
    echo "[start] FAILED; tail logs:" >&2
    docker logs --tail 30 "$NAME" 2>&1 | sed 's/^/  /' >&2
    return 1
  fi
}

do_stop() {
  acquire_lock; trap release_lock EXIT
  if ! docker inspect "$NAME" --format '{{.Id}}' >/dev/null 2>&1; then
    echo "$NAME not present"
    return 0
  fi
  echo "[stop] $NAME"
  docker stop --time 30 "$NAME" 2>&1 | tail -1
}

do_restart() {
  do_stop
  sleep 1
  do_start
}

do_status() {
  echo "=== container ==="
  docker inspect "$NAME" --format 'name={{.Name}} state={{.State.Status}} pid={{.State.Pid}} started={{.State.StartedAt}}' 2>/dev/null || echo "$NAME not present"
  echo "=== port $PORT ==="
  ss -lntp "sport = :$PORT" 2>/dev/null | grep LISTEN || echo "no listener on :$PORT"
  echo "=== last 5 log lines ==="
  docker logs --tail 5 "$NAME" 2>&1 | sed 's/^/  /'
}

case "${1-start}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_restart ;;
  status)  do_status ;;
  *) echo "用法: $0 {start|stop|restart|status}"; exit 1 ;;
esac
