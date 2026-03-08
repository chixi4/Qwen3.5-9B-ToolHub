# Qwen3.5-9B ToolHub

基于 Qwen3.5-9B 多模态模型 + 可调用工具的本地一体化部署方案

✅联网搜索、看图、读文件

模型推理在本机 GPU 完成，可通过 API 接口使用

需要 Windows 10/11、NVIDIA 显卡（≥ 8 GB 显存）、Python 3.10+

## 启动

```
1. 双击 bootstrap.bat   ← 首次安装，下载约 6 GB 模型
2. .\start_8080_toolhub_stack.cmd start
3. 浏览器打开 http://127.0.0.1:8080
停止：.\start_8080_toolhub_stack.cmd stop
```

每次启动需要 30–60 秒加载模型。

## 其他路线

上面是 Windows 默认主线。如果你的情况不同，可以选择：

- **Docker Compose** — 已装好 Docker 且 GPU 容器可用的环境。`docker compose up --build` 即可。→ [详细说明](docs/DOCKER_COMPOSE.md)
- **WSL** — 已有 WSL 环境的用户。`./install.sh` + `./start_8080_toolhub_stack.sh start`，底层复用 Windows 主链路。
- **Q8 量化（约占用10.2 GB）** — 如果你的显存 ≥ 12 GB ，双击 `bootstrap_q8.bat`，脚本自动切换模型并下载。

## 能做什么

- 联网搜索，抓取网页，提炼摘要并附来源
- 上传图片直接提问，支持局部放大和以图搜图
- 只读浏览本机文件，让 AI 帮你看文档和日志
- 内置思维链，复杂问题可展开推理过程
- OpenAI 兼容 API（`http://127.0.0.1:8080/v1`），可对接任意兼容客户端

## 文档

- [详细介绍](docs/QUICKSTART.md) — 安装、启动、配置、服务管理
- [常见问题](docs/TROUBLESHOOTING.md) — 排障指引
- [Docker Compose](docs/DOCKER_COMPOSE.md) — 容器化部署

## 致谢

- [Qwen3.5](https://github.com/QwenLM/Qwen3) — 通义千问多模态大模型
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — 高性能 GGUF 推理引擎
