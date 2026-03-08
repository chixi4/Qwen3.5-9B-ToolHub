#!/usr/bin/env python3
import argparse
import os
import threading
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any, Dict, List, Set, Tuple

import requests
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.concurrency import run_in_threadpool

from toolhub_gateway_agent import (
    build_non_stream_response,
    run_chat_completion,
    stream_chat_completion,
)

DEFAULT_GATEWAY_HOST = '127.0.0.1'
DEFAULT_GATEWAY_PORT = 8080
DEFAULT_BACKEND_BASE = 'http://127.0.0.1:8081'
DEFAULT_MODEL_SERVER = 'http://127.0.0.1:8081/v1'
DEFAULT_TIMEOUT_SEC = 180
DEFAULT_BACKEND_WAIT_HINT = ''
DEFAULT_ACCESS_URLS = 'http://127.0.0.1:8080,http://localhost:8080'
READY_ANNOUNCE_INTERVAL_SEC = 2
WAIT_LOG_INTERVAL_SEC = 10
WARMUP_MESSAGE = '请只回复一个字：好'
WARMUP_PARSE_ERROR_MARKER = 'Failed to parse input'
STREAM_CHUNK_BYTES = 8192
SUPPORTED_PROXY_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'HEAD']
HOP_HEADERS = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailers',
    'transfer-encoding',
    'upgrade',
}
LOCAL_CONFIG_KEY = 'LlamaCppWebui.config'
LOCAL_OVERRIDES_KEY = 'LlamaCppWebui.userOverrides'
WEBUI_SETTINGS_PATCH = f"""
<script>
(function () {{
  try {{
    var cfgKey = '{LOCAL_CONFIG_KEY}';
    var ovKey = '{LOCAL_OVERRIDES_KEY}';
    var cfg = JSON.parse(localStorage.getItem(cfgKey) || '{{}}');
    cfg.showMessageStats = true;
    cfg.keepStatsVisible = false;
    cfg.showThoughtInProgress = true;
    cfg.disableReasoningParsing = false;
    localStorage.setItem(cfgKey, JSON.stringify(cfg));

    var overrides = JSON.parse(localStorage.getItem(ovKey) || '[]');
    var set = new Set(Array.isArray(overrides) ? overrides : []);
    ['showMessageStats', 'keepStatsVisible', 'showThoughtInProgress', 'disableReasoningParsing']
      .forEach(function (k) {{ set.add(k); }});
    localStorage.setItem(ovKey, JSON.stringify(Array.from(set)));
  }} catch (e) {{
    console.error('webui settings patch failed', e);
  }}
}})();
</script>
<style>
.chat-processing-info-container {{
  display: none !important;
}}
</style>
""".strip()
BACKEND_LOADING_HTML = """
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ToolHub 正在准备中</title>
  <style>
    :root {
      color-scheme: light;
      font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
      background: #0f172a;
      color: #e2e8f0;
    }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at top, rgba(59, 130, 246, 0.18), transparent 45%),
        linear-gradient(180deg, #111827, #020617);
    }
    main {
      width: min(680px, calc(100vw - 32px));
      padding: 28px;
      border-radius: 20px;
      background: rgba(15, 23, 42, 0.88);
      border: 1px solid rgba(148, 163, 184, 0.24);
      box-shadow: 0 24px 80px rgba(15, 23, 42, 0.45);
    }
    h1 {
      margin: 0 0 12px;
      font-size: 28px;
    }
    .status {
      display: flex;
      align-items: center;
      gap: 16px;
      margin-bottom: 18px;
    }
    .spinner-shell {
      position: relative;
      width: 40px;
      height: 40px;
      flex: 0 0 auto;
    }
    .spinner-ring {
      position: absolute;
      inset: 0;
      border-radius: 999px;
      border: 3px solid rgba(148, 163, 184, 0.16);
      border-top-color: #93c5fd;
      border-right-color: rgba(96, 165, 250, 0.92);
      animation: spin 12s steps(12, end) infinite;
      will-change: transform;
      transform: translateZ(0);
    }
    .spinner-ring::after {
      content: "";
      position: absolute;
      top: 3px;
      left: 50%;
      width: 7px;
      height: 7px;
      margin-left: -3.5px;
      border-radius: 999px;
      background: #e0f2fe;
      box-shadow: 0 0 12px rgba(96, 165, 250, 0.78);
    }
    .spinner-core {
      position: absolute;
      inset: 9px;
      border-radius: 999px;
      background:
        radial-gradient(circle, rgba(191, 219, 254, 0.96) 0, rgba(147, 197, 253, 0.82) 34%, rgba(59, 130, 246, 0.18) 65%, transparent 72%);
    }
    p {
      margin: 10px 0;
      line-height: 1.7;
      color: #cbd5e1;
    }
    .state-line {
      margin-top: 14px;
      color: #93c5fd;
    }
    .elapsed-line {
      margin-top: 8px;
      color: #cbd5e1;
      font-variant-numeric: tabular-nums;
    }
    .hint-box {
      margin-top: 16px;
      padding: 14px 16px;
      border-radius: 14px;
      background: rgba(15, 23, 42, 0.72);
      border: 1px solid rgba(148, 163, 184, 0.18);
    }
    details {
      margin-top: 16px;
      color: #94a3b8;
    }
    summary {
      cursor: pointer;
    }
    pre {
      margin: 10px 0 0;
      padding: 12px;
      border-radius: 12px;
      background: rgba(2, 6, 23, 0.86);
      border: 1px solid rgba(148, 163, 184, 0.16);
      color: #cbd5e1;
      white-space: pre-wrap;
      word-break: break-word;
      font-family: "Cascadia Code", "Consolas", monospace;
      font-size: 13px;
      line-height: 1.6;
    }
    code {
      font-family: "Cascadia Code", "Consolas", monospace;
      color: #f8fafc;
    }
    @keyframes spin {
      from { transform: rotate(0deg); }
      to { transform: rotate(360deg); }
    }
    @media (prefers-reduced-motion: reduce) {
      .spinner-ring {
        animation-duration: 12s;
      }
    }
  </style>
</head>
<body>
  <main>
    <div class="status">
      <div class="spinner-shell" aria-hidden="true">
        <div class="spinner-ring"></div>
        <div class="spinner-core"></div>
      </div>
      <h1>ToolHub 正在准备中</h1>
    </div>
    <p>网关已经启动，但模型后端暂时还没有就绪。</p>
    <p>如果这是第一次启动，程序可能正在下载模型文件，或者正在把模型加载到 GPU。</p>
    <p>页面会停留在这个等待界面里，并自动检查后端状态。准备完成后会自动进入聊天界面，不再整页反复刷新。</p>
    <p class="state-line" id="state-line">正在检查后端状态...</p>
    <p class="elapsed-line" id="elapsed-line">已等待 0 秒</p>
    <div class="hint-box">
      <p>如果你是刚在终端里执行了启动命令，最直接的进度信息通常就在那个终端窗口里。</p>
      __HINT_BLOCK__
    </div>
    <details>
      <summary>查看技术详情</summary>
      <pre>__DETAIL__</pre>
    </details>
  </main>
  <script>
    (function () {
      var stateLine = document.getElementById('state-line');
      var elapsedLine = document.getElementById('elapsed-line');
      var healthUrl = '/gateway/health';
      var startedAt = Date.now();

      function updateState(message) {
        if (stateLine) {
          stateLine.textContent = message;
        }
      }

      function updateElapsed() {
        if (!elapsedLine) {
          return;
        }
        var elapsedSec = Math.floor((Date.now() - startedAt) / 1000);
        elapsedLine.textContent = '已等待 ' + elapsedSec + ' 秒';
      }

      async function pollHealth() {
        try {
          var response = await fetch(healthUrl, { cache: 'no-store' });
          var payload = await response.json();
          if (payload.status === 'ok') {
            updateState('后端已经就绪，正在进入聊天界面...');
            updateElapsed();
            window.location.reload();
            return;
          }
          updateState('模型仍在准备中，页面会自动继续等待。');
        } catch (error) {
          updateState('暂时还连不上后端，继续等待即可。');
        }
        window.setTimeout(pollHealth, 4000);
      }

      updateElapsed();
      window.setInterval(updateElapsed, 1000);
      window.setTimeout(pollHealth, 1200);
    })();
  </script>
</body>
</html>
""".strip()


@dataclass(frozen=True)
class GatewayConfig:
    backend_base: str
    model_server: str
    gateway_host: str
    gateway_port: int
    timeout_sec: int = DEFAULT_TIMEOUT_SEC
    backend_wait_hint: str = DEFAULT_BACKEND_WAIT_HINT
    access_urls: Tuple[str, ...] = ()


@dataclass
class GatewayState:
    ready_event: threading.Event


def parse_args() -> GatewayConfig:
    parser = argparse.ArgumentParser(description='Run 8080 toolhub gateway with 8081 llama-server backend.')
    parser.add_argument('--host', default=os.getenv('GATEWAY_HOST', DEFAULT_GATEWAY_HOST))
    parser.add_argument('--port', type=int, default=int(os.getenv('GATEWAY_PORT', str(DEFAULT_GATEWAY_PORT))))
    parser.add_argument('--backend-base', default=os.getenv('BACKEND_BASE', DEFAULT_BACKEND_BASE))
    parser.add_argument('--model-server', default=os.getenv('MODEL_SERVER', DEFAULT_MODEL_SERVER))
    parser.add_argument('--timeout-sec', type=int, default=int(os.getenv('GATEWAY_TIMEOUT_SEC', str(DEFAULT_TIMEOUT_SEC))))
    parser.add_argument('--backend-wait-hint', default=os.getenv('BACKEND_WAIT_HINT', DEFAULT_BACKEND_WAIT_HINT))
    parser.add_argument('--access-urls', default=os.getenv('ACCESS_URLS', DEFAULT_ACCESS_URLS))
    args = parser.parse_args()
    return GatewayConfig(
        backend_base=args.backend_base.rstrip('/'),
        model_server=args.model_server.rstrip('/'),
        gateway_host=args.host,
        gateway_port=args.port,
        timeout_sec=args.timeout_sec,
        backend_wait_hint=args.backend_wait_hint.strip(),
        access_urls=parse_access_urls(args.access_urls),
    )


def parse_access_urls(raw: str) -> Tuple[str, ...]:
    urls = [item.strip() for item in raw.split(',') if item.strip()]
    return tuple(dict.fromkeys(urls))


def filtered_headers(headers: Dict[str, str]) -> Dict[str, str]:
    blocked = HOP_HEADERS | {'host', 'content-length', 'proxy-connection'}
    return {key: value for key, value in headers.items() if key.lower() not in blocked}


def drop_headers_ci(headers: Dict[str, str], names: Set[str]) -> Dict[str, str]:
    lowered = {name.lower() for name in names}
    return {key: value for key, value in headers.items() if key.lower() not in lowered}


def build_backend_url(base: str, path: str, query: str) -> str:
    if not query:
        return f'{base}{path}'
    return f'{base}{path}?{query}'


def stream_upstream(upstream: requests.Response):
    try:
        for chunk in upstream.iter_content(chunk_size=STREAM_CHUNK_BYTES):
            if chunk:
                yield chunk
    finally:
        upstream.close()


def inject_webui_settings(html: str) -> str:
    if WEBUI_SETTINGS_PATCH in html:
        return html
    if '<head>' in html:
        return html.replace('<head>', f'<head>\n{WEBUI_SETTINGS_PATCH}\n', 1)
    if '<body>' in html:
        return html.replace('<body>', f'<body>\n{WEBUI_SETTINGS_PATCH}\n', 1)
    return f'{WEBUI_SETTINGS_PATCH}\n{html}'


def build_backend_loading_response(detail: str, wait_hint: str) -> Response:
    safe_detail = detail.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    hint_block = ''
    if wait_hint:
        safe_hint = wait_hint.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        hint_block = f'<p>如果你想单独查看后端准备进度，可以执行：<br><code>{safe_hint}</code></p>'
    html = BACKEND_LOADING_HTML.replace('__DETAIL__', safe_detail).replace('__HINT_BLOCK__', hint_block)
    return Response(
        content=html,
        status_code=200,
        media_type='text/html; charset=utf-8',
        headers={'Cache-Control': 'no-store, max-age=0'},
    )


def is_root_request(request: Request, path: str) -> bool:
    return request.method == 'GET' and path in {'/', '/index.html'}


def is_backend_wait_status(status_code: int) -> bool:
    return status_code in {502, 503, 504}


def format_access_urls(access_urls: Tuple[str, ...]) -> str:
    return ' '.join(access_urls)


def check_backend_ready(cfg: GatewayConfig) -> bool:
    try:
        response = requests.get(f'{cfg.backend_base}/health', timeout=cfg.timeout_sec)
        response.raise_for_status()
    except Exception:  # noqa: BLE001
        return False
    return True


def announce_access_urls(cfg: GatewayConfig) -> None:
    if not cfg.access_urls:
        return
    print(
        f'[toolhub-gateway] 网页入口已经开放，正在加载模型，完成后可访问: {format_access_urls(cfg.access_urls)}',
        flush=True,
    )


def announce_backend_ready(cfg: GatewayConfig) -> None:
    if not cfg.access_urls:
        return
    print(
        f'[toolhub-gateway] 模型已完成加载和预热，可以打开: {format_access_urls(cfg.access_urls)}',
        flush=True,
    )


def is_gateway_ready(state: GatewayState) -> bool:
    return state.ready_event.is_set()


def warmup_model(cfg: GatewayConfig) -> Tuple[bool, str]:
    payload = {
        'messages': [{'role': 'user', 'content': WARMUP_MESSAGE}],
        'max_tokens': 1,
        'stream': False,
        'temperature': 0,
    }
    try:
        response = requests.post(
            f'{cfg.model_server}/chat/completions',
            json=payload,
            timeout=cfg.timeout_sec,
        )
    except Exception as exc:  # noqa: BLE001
        return False, f'模型预热请求失败: {exc}'
    if response.ok:
        return True, '模型预热已完成'
    body = response.text.strip()
    if response.status_code == 500 and WARMUP_PARSE_ERROR_MARKER in body:
        return True, '模型首轮预热已经完成'
    return False, f'模型预热暂未完成: HTTP {response.status_code} {body[:200]}'


def run_ready_announcer(cfg: GatewayConfig, state: GatewayState) -> None:
    last_wait_detail = ''
    last_wait_log_at = 0.0
    announce_access_urls(cfg)
    while True:
        if check_backend_ready(cfg):
            ready, wait_detail = warmup_model(cfg)
        else:
            ready, wait_detail = False, '后端健康检查尚未通过'
        if ready:
            state.ready_event.set()
            announce_backend_ready(cfg)
            return
        now = time.monotonic()
        if wait_detail != last_wait_detail or (now - last_wait_log_at) >= WAIT_LOG_INTERVAL_SEC:
            print(f'[toolhub-gateway] 后端仍在准备中: {wait_detail}', flush=True)
            last_wait_detail = wait_detail
            last_wait_log_at = now
        time.sleep(READY_ANNOUNCE_INTERVAL_SEC)


async def handle_gateway_health(cfg: GatewayConfig, state: GatewayState) -> Dict[str, Any]:
    status = 'ok' if is_gateway_ready(state) else 'warming'
    backend_error = ''
    try:
        health = requests.get(f'{cfg.backend_base}/health', timeout=cfg.timeout_sec)
        health.raise_for_status()
    except Exception as exc:  # noqa: BLE001
        status = 'degraded'
        backend_error = str(exc)
    return {'status': status, 'backend_base': cfg.backend_base, 'backend_error': backend_error}


async def handle_chat_completions(request: Request, cfg: GatewayConfig) -> Response:
    payload = await request.json()
    stream = bool(payload.get('stream', False))
    if stream:
        try:
            iterator = stream_chat_completion(payload, cfg.model_server, cfg.timeout_sec)
        except Exception as exc:  # noqa: BLE001
            error = {'error': {'code': 500, 'type': 'gateway_error', 'message': str(exc)}}
            return JSONResponse(status_code=500, content=error)
        return StreamingResponse(iterator, media_type='text/event-stream')

    try:
        result = await run_in_threadpool(run_chat_completion, payload, cfg.model_server, cfg.timeout_sec)
    except Exception as exc:  # noqa: BLE001
        error = {'error': {'code': 500, 'type': 'gateway_error', 'message': str(exc)}}
        return JSONResponse(status_code=500, content=error)

    answer = result['answer']
    model = result['model']
    reasoning = result.get('reasoning', '')
    return JSONResponse(content=build_non_stream_response(answer, model, reasoning))


async def handle_proxy(request: Request, full_path: str, cfg: GatewayConfig, state: GatewayState) -> Response:
    path = '/' + full_path
    if is_root_request(request, path) and not is_gateway_ready(state):
        return build_backend_loading_response('模型正在加载或预热，完成后会自动进入聊天界面。', cfg.backend_wait_hint)
    url = build_backend_url(cfg.backend_base, path, request.url.query)
    headers = filtered_headers(dict(request.headers))
    body = await request.body()

    try:
        upstream = requests.request(
            method=request.method,
            url=url,
            headers=headers,
            data=body,
            stream=True,
            timeout=cfg.timeout_sec,
            allow_redirects=False,
        )
    except Exception as exc:  # noqa: BLE001
        if is_root_request(request, path):
            return build_backend_loading_response(str(exc), cfg.backend_wait_hint)
        if request.method == 'GET' and path == '/favicon.ico':
            return Response(status_code=204)
        error = {'error': {'type': 'proxy_error', 'message': str(exc)}}
        return JSONResponse(status_code=502, content=error)

    response_headers = filtered_headers(dict(upstream.headers))
    content_type = upstream.headers.get('content-type', '')
    if is_root_request(request, path) and is_backend_wait_status(upstream.status_code):
        detail = upstream.text.strip() or f'backend returned {upstream.status_code}'
        upstream.close()
        return build_backend_loading_response(detail, cfg.backend_wait_hint)
    if request.method == 'GET' and path == '/favicon.ico' and is_backend_wait_status(upstream.status_code):
        upstream.close()
        return Response(status_code=204)
    if 'text/event-stream' in content_type:
        return StreamingResponse(
            stream_upstream(upstream),
            status_code=upstream.status_code,
            headers=response_headers,
            media_type='text/event-stream',
        )

    is_webui_html = (
        request.method == 'GET'
        and path in {'/', '/index.html'}
        and upstream.status_code == 200
        and 'text/html' in content_type
    )
    if is_webui_html:
        encoding = upstream.encoding or 'utf-8'
        html = upstream.content.decode(encoding, errors='replace')
        injected = inject_webui_settings(html)
        upstream.close()
        clean_headers = drop_headers_ci(response_headers, {'content-encoding', 'content-length', 'etag'})
        return Response(
            content=injected.encode('utf-8'),
            status_code=200,
            headers=clean_headers,
            media_type='text/html; charset=utf-8',
        )

    upstream.raw.decode_content = False
    data = upstream.raw.read(decode_content=False)
    upstream.close()
    return Response(content=data, status_code=upstream.status_code, headers=response_headers)


def create_app(cfg: GatewayConfig, state: GatewayState) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_: FastAPI):
        threading.Thread(target=run_ready_announcer, args=(cfg, state), daemon=True).start()
        yield

    app = FastAPI(title='Qwen3.5 ToolHub Gateway 8080', lifespan=lifespan)

    @app.get('/gateway/health')
    async def gateway_health() -> Dict[str, Any]:
        return await handle_gateway_health(cfg, state)

    @app.post('/v1/chat/completions')
    async def chat_completions(request: Request) -> Response:
        return await handle_chat_completions(request, cfg)

    @app.api_route('/{full_path:path}', methods=SUPPORTED_PROXY_METHODS)
    async def proxy_all(request: Request, full_path: str) -> Response:
        return await handle_proxy(request, full_path, cfg, state)

    return app


def main() -> None:
    cfg = parse_args()
    state = GatewayState(ready_event=threading.Event())
    app = create_app(cfg, state)
    uvicorn.run(app, host=cfg.gateway_host, port=cfg.gateway_port, log_level='info')


if __name__ == '__main__':
    main()
