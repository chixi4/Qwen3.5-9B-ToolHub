# Docker Compose

ToolHub 提供 Docker Compose 入口，适合 Linux 主机部署，或不想在 Windows 宿主机安装 Python 的用户。这是一条可选路线，不替代 Windows 原生脚本主线。

---

## 前提条件

- Docker 和 Docker Compose 已安装
- NVIDIA GPU 驱动已安装，且 NVIDIA Container Toolkit 可用

验证 GPU 容器环境：

```bash
docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi
```

---

## 启动与停止

```bash
docker compose up --build         # 前台启动
docker compose up --build -d      # 后台启动
docker compose down               # 停止
```

首次启动时后端容器会自动下载模型文件，之后缓存在 Docker 命名卷 `toolhub-models` 中。

启动后浏览器访问 [http://127.0.0.1:8080](http://127.0.0.1:8080)。

如果后端还在下载模型或加载模型到 GPU，浏览器会先显示准备中页面。此时直接查看：

```bash
docker compose logs -f backend
```

确认下载和加载进度即可。

---

## 容器结构

Compose 启动两个服务：

| 服务 | 镜像基础 | 职责 |
| --- | --- | --- |
| `gateway` | `python:3.11-slim` | 网关层，提供网页入口和 OpenAI 兼容 API（端口 8080） |
| `backend` | `ghcr.io/ggml-org/llama.cpp:server-cuda` | 模型后端，GPU 推理（端口 8081） |

架构与 Windows 原生路线一致：浏览器访问网关，网关将推理请求转发给后端。网关容器通过只读方式挂载项目目录（`/workspace`），文件系统访问行为与 Windows 路线保持一致。

---

## 模型管理

模型不会打进镜像，由后端容器首次启动时从 Hugging Face 下载，缓存在命名卷 `toolhub-models` 中。默认下载 Q4_K_M 量化。

如需切换到 Q8，在 `.env` 中将 `MODEL_GGUF_URL` 改为 Q8 下载地址，也可以先在宿主机执行 `.\install_q8.cmd` 让它自动修改，然后重启容器：

```bash
docker compose down
docker compose up --build -d
```

> 容器内模型缓存（命名卷）和 Windows 路线的本地缓存（`.tmp/models/`）是两套独立缓存，互不影响。

---

## 配置

Compose 通过 `.env` 文件读取配置。以下变量会影响容器行为：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GATEWAY_PORT` | `8080` | 网关对外端口 |
| `BACKEND_PORT` | `8081` | 后端对外端口 |
| `THINK_MODE` | `think-on` | 思考模式 |
| `CTX_SIZE` | `16384` | 上下文窗口大小 |
| `IMAGE_MIN_TOKENS` | `256` | 图像最小 token 数 |
| `IMAGE_MAX_TOKENS` | `1024` | 图像最大 token 数 |
| `MMPROJ_OFFLOAD` | `off` | 视觉投影卸载开关 |

修改 `.env` 后重启容器生效。
