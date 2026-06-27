#!/usr/bin/env python3
"""NotchStatus durum güncelleyici - Claude Code hook'larından çağrılır.
Asla stdout'a yazmaz (UserPromptSubmit hook stdout'u context'e ekler), asla hata fırlatmaz.
Kullanım: notch_update.py <mode>   mode = start|working|tool|stop
"""
import sys, json, os, time

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "working"
    home = os.path.expanduser("~")
    status_path = os.path.join(home, ".claude", "notch-status.json")

    # hook stdin JSON
    inp = {}
    try:
        raw = sys.stdin.read()
        if raw.strip():
            inp = json.loads(raw)
    except Exception:
        inp = {}

    # mevcut durumu oku
    existing = {}
    try:
        with open(status_path) as f:
            existing = json.load(f)
    except Exception:
        existing = {}

    now = time.time()

    # token toplamı: yalnız start/stop'ta transcript'i tara (tool'larda gecikme yapma)
    def count_tokens():
        tp = inp.get("transcript_path")
        if not tp or not os.path.exists(tp):
            return existing.get("tokens", 0)
        total = 0
        try:
            with open(tp) as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                        u = (rec.get("message") or {}).get("usage") or {}
                        total += int(u.get("input_tokens", 0)) + int(u.get("output_tokens", 0)) \
                            + int(u.get("cache_creation_input_tokens", 0))   # cache_read HARİÇ (Swift ile tutarlı)
                    except Exception:
                        continue
        except Exception:
            return existing.get("tokens", 0)
        return total or existing.get("tokens", 0)

    if mode == "start":
        baseline = count_tokens()
        out = {"state": "working", "label": "Thinking", "tokens": baseline,
               "tokenBaseline": baseline, "turnTokens": 0, "startedAt": now, "endedAt": 0, "updatedAt": now}
    elif mode == "tool":
        base = existing.get("tokenBaseline", existing.get("tokens", 0)); toks = existing.get("tokens", 0)
        out = {"state": "working", "label": inp.get("tool_name") or existing.get("label", "Tool"),
               "tokens": toks, "tokenBaseline": base, "turnTokens": max(0, toks - base),
               "startedAt": existing.get("startedAt", now), "endedAt": 0, "updatedAt": now}
    elif mode == "stop":
        toks = count_tokens(); base = existing.get("tokenBaseline", 0); turn = max(0, toks - base)
        started = existing.get("startedAt", now)
        # bildirim + ses NotchStatus app'i tarafından gönderilir (NotchStatus adına, izinli, tutarlı)
        out = {"state": "idle", "label": "Ready", "tokens": toks, "tokenBaseline": base,
               "turnTokens": turn, "startedAt": started, "endedAt": now, "updatedAt": now}
    else:  # working
        base = existing.get("tokenBaseline", existing.get("tokens", 0)); toks = existing.get("tokens", 0)
        out = {"state": "working", "label": existing.get("label", "Working"),
               "tokens": toks, "tokenBaseline": base, "turnTokens": max(0, toks - base),
               "startedAt": existing.get("startedAt", now), "endedAt": 0, "updatedAt": now}

    try:
        os.makedirs(os.path.dirname(status_path), exist_ok=True)
        with open(status_path, "w") as f:
            json.dump(out, f)
    except Exception:
        pass

if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
