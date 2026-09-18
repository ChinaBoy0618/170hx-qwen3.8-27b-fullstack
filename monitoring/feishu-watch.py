#!/usr/bin/env python3
"""760T 看门狗：轮询 Prometheus 告警规则 → 加签推飞书（去重 + 自愈/恢复 + 自监控）。

无 Alertmanager。Prometheus 自己评 rules.yml 里的告警，本脚本每 2min 读
/api/v1/alerts（firing 集），与上次状态对比：新 firing → 推；消失 → 推"恢复"。
另外自监控：若 Prometheus 自身不可达（up{job="prometheus"}==0 或抓取失败），
也推一条 critical，覆盖"监控栈自己挂了"的场景。
只推不写生产；读 feishu.env 拿 webhook+secret。
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.request

PROM = "http://127.0.0.1:9090"
HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.path.join(HERE, "feishu.env")
STATE = os.path.join(HERE, "watch.state.json")


def load_env():
    kv = {}
    if os.path.exists(ENV):
        for line in open(ENV, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip().strip('"').strip("'")
    return kv


def feishu_sign(timestamp, secret):
    string_to_sign = "{}\n{}".format(timestamp, secret)
    hmac_code = hmac.new(string_to_sign.encode("utf-8"), digestmod=hashlib.sha256).digest()
    return base64.b64encode(hmac_code).decode("utf-8")


def feishu_send(webhook, secret, title, lines):
    ts = str(int(time.time()))
    content = {"post": {"zh_cn": {"title": title, "content": [[{"tag": "text", "text": ln}] for ln in lines]}}}
    payload = {"msg_type": "post", "content": content}
    if secret:
        payload["timestamp"] = ts
        payload["sign"] = feishu_sign(ts, secret)
    req = urllib.request.Request(
        webhook, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}, method="POST")
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                body = r.read().decode("utf-8", "replace")
                # 飞书成功: {"code":0,"msg":"success"...} 或 {"StatusCode":0}
                if "success" in body or '"code":0' in body or '"StatusCode":0' in body or '"status_code":0' in body:
                    return True
                print("feishu resp(non-ok):", body[:200], file=sys.stderr)
        except Exception as e:  # noqa: BLE001
            print("feishu send err (try %d): %s" % (attempt, e), file=sys.stderr)
        if attempt == 1:
            time.sleep(3)
    return False


def _app_token_cache_read():
    try:
        d = json.load(open("/tmp/feishu-app-token.json"))
        if d.get("expire", 0) > time.time() + 60:
            return d["token"]
    except Exception:  # noqa: BLE001
        pass
    return None


def app_token(app_id, app_secret):
    tok = _app_token_cache_read()
    if tok:
        return tok
    body = json.dumps({"app_id": app_id, "app_secret": app_secret}).encode("utf-8")
    req = urllib.request.Request(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        data=body, headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.loads(r.read().decode("utf-8", "replace"))
    if d.get("code") != 0 or not d.get("tenant_access_token"):
        raise RuntimeError("token fetch fail: " + str(d)[:200])
    tok = d["tenant_access_token"]
    try:
        json.dump({"token": tok, "expire": time.time() + d.get("expire", 7000) - 300},
                  open("/tmp/feishu-app-token.json", "w"))
    except Exception:  # noqa: BLE001
        pass
    return tok


def app_send(app_id, app_secret, chat_id, title, lines, dm_open_id=""):
    tok = app_token(app_id, app_secret)
    if chat_id:
        receive, rtype = chat_id, "chat_id"
    elif dm_open_id:
        receive, rtype = dm_open_id, "open_id"
    else:
        raise RuntimeError("FEISHU_CHAT_ID 与 FEISHU_DM_OPEN_ID 均未配置")
    content = {"post": {"zh_cn": {"title": title,
                                  "content": [[{"tag": "text", "text": ln}] for ln in lines]}}}
    body = json.dumps({"receive_id": receive, "msg_type": "post",
                       "content": json.dumps(content, ensure_ascii=False)}).encode("utf-8")
    req = urllib.request.Request(
        "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=" + rtype,
        data=body, headers={"Authorization": "Bearer " + tok,
                            "Content-Type": "application/json"}, method="POST")
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                d = json.loads(r.read().decode("utf-8", "replace"))
            if d.get("code") == 0:
                return True
            raise RuntimeError("send resp: " + str(d)[:200])
        except urllib.error.HTTPError as e:
            raise RuntimeError("send HTTP%d: %s" % (e.code, e.read()[:200].decode("utf-8", "replace")))
        except RuntimeError:
            raise
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            time.sleep(3)
    return False


def http_json(url, timeout=15):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def prom_up():
    """Prometheus 自身是否可达（读 up{job=prometheus} 或直接 /-/healthy）。"""
    try:
        data = http_json(PROM + "/api/v1/query?query=up{job=%22prometheus%22}")
        res = data.get("data", {}).get("result", [])
        if res and float(res[0]["value"][1]) == 1.0:
            return True
        return False
    except Exception:  # noqa: BLE001
        return False


def firing_alerts():
    """返回 {key: alert_dict}，key=alertname|instance。"""
    out = {}
    try:
        data = http_json(PROM + "/api/v1/alerts")
    except Exception as e:  # noqa: BLE001
        print("alerts query err:", e, file=sys.stderr)
        return out
    for a in data.get("data", {}).get("alerts", []):
        if a.get("state") != "firing":
            continue
        name = a.get("labels", {}).get("alertname", "?")
        inst = a.get("labels", {}).get("instance", "")
        sev = a.get("labels", {}).get("severity", "info")
        ann = a.get("annotations", {}) or {}
        out["%s|%s" % (name, inst)] = {
            "name": name, "inst": inst, "sev": sev,
            "summary": ann.get("summary", ""), "desc": ann.get("description", ""),
            "startsAt": a.get("activeAt", ""),
        }
    return out


def load_state():
    if os.path.exists(STATE):
        try:
            return json.loads(open(STATE, encoding="utf-8").read())
        except Exception:  # noqa: BLE001
            pass
    return {"firing": {}}


def save_state(st):
    tmp = STATE + ".tmp"
    json.dump(st, open(tmp, "w", encoding="utf-8"), ensure_ascii=False)
    os.replace(tmp, STATE)


def main():
    env = load_env()
    webhook = env.get("FEISHU_WEBHOOK", "")
    if "FILL_ME" in webhook:
        webhook = ""
    secret = env.get("FEISHU_SECRET", "")
    app_id = env.get("FEISHU_APP_ID", "")
    app_secret = env.get("FEISHU_APP_SECRET", "")
    chat_id = env.get("FEISHU_CHAT_ID", "")
    st = load_state()
    prev = st.get("firing", {})
    cur = firing_alerts()
    prom_ok = prom_up()

    new = {k: v for k, v in cur.items() if k not in prev}
    resolved = {k: prev[k] for k in prev if k not in cur}

    lines = []
    title = None
    # 自监控
    if not prom_ok:
        title = "🔴 [critical] 760 监控栈 Prometheus 不可达"
        lines.append("Prometheus(:9090) 抓取失败，监控本身可能已挂，需人工介入。")
    if new:
        title = title or ("🔴 760 告警 %d 条" % len(new))
        for k, v in sorted(new.items()):
            tag = {"critical": "🔴", "warning": "🟡"}.get(v["sev"], "ℹ️")
            lines.append("%s %s" % (tag, v["summary"] or v["name"]))
            if v["desc"]:
                lines.append("    " + v["desc"])
    if resolved:
        rt = "🟢 760 恢复 %d 条" % len(resolved)
        if title:
            lines.append("---")
            lines.append(rt)
        else:
            title = rt
        for k, v in sorted(resolved.items()):
            lines.append("  ✔ " + (v.get("summary") or v.get("name", "")))

    test_mode = "--test" in sys.argv
    if lines or test_mode:
        if test_mode and not lines:
            title = "760 watch test"
            lines = ["watch --test 通道自检 @ " + time.strftime("%F %T")]
        sent = False
        if webhook:
            sent = feishu_send(webhook, secret, title or "760 watch", lines)
        elif app_id and app_secret:
            try:
                sent = app_send(app_id, app_secret, chat_id, title or "760 watch", lines,
                                env.get("FEISHU_DM_OPEN_ID", ""))
            except Exception as e:  # noqa: BLE001
                print("app channel err:", e, file=sys.stderr)
        else:
            print("no FEISHU_WEBHOOK / FEISHU_APP_ID set; would send:", title, file=sys.stderr)
        if sent:
            print("sent:", title or "760 watch")

    save_state({"firing": {k: v for k, v in cur.items()}})
    if lines:
        print(time.strftime("%F %T"), "| new=%d resolved=%d prom_ok=%s" % (len(new), len(resolved), prom_ok))


if __name__ == "__main__":
    main()
