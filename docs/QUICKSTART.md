# 快速开始

从零到能用的完整说明。默认路线为 Windows 原生，WSL 和 Docker Compose 见末尾。

---

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11 |
| GPU | NVIDIA，驱动 ≥ 525，建议 ≥ 8 GB 显存 |
| Python | 3.10+，已加入 PATH |
| 磁盘 | ≥ 20 GB 可用空间 |

> Q4_K_M 量化下模型加上视觉投影约占 6.1 GB 显存。8 GB 显存可正常运行。

Docker Compose 路线不需要在宿主机安装 Python，系统要求见 [Docker Compose 文档](DOCKER_COMPOSE.md)。

---

## 1. 安装

双击 `bootstrap.bat`，或在命令行执行：

```powershell
.\install.cmd
```

安装脚本会自动完成：

- 创建 Python 虚拟环境并安装依赖
- 下载 llama.cpp CUDA 运行时
- 下载 Qwen3.5-9B Q4_K_M 主模型与 mmproj 视觉投影模型

首次安装需要下载约 6 GB 模型文件，请确保网络通畅。

---

## 2. 启动

```powershell
.\start_8080_toolhub_stack.cmd start
```

首次启动需要 30–60 秒加载模型到 GPU。看到"栈已启动"即表示就绪。

---

## 3. 打开网页

浏览器访问 [http://127.0.0.1:8080](http://127.0.0.1:8080)。

---

## 4. 服务管理

```powershell
.\start_8080_toolhub_stack.cmd start     # 启动
.\start_8080_toolhub_stack.cmd stop      # 停止
.\start_8080_toolhub_stack.cmd restart   # 重启
.\start_8080_toolhub_stack.cmd status    # 查看状态
.\start_8080_toolhub_stack.cmd logs      # 查看日志
```

---

## 5. 可选：升级到 Q8 量化

显存 ≥ 12 GB 时，可以切换到 Q8 获得更高推理精度。

双击 `bootstrap_q8.bat`，或执行 `.\install_q8.cmd`。脚本会自动修改 `.env` 中的模型路径和下载地址，然后开始下载。视觉模型 mmproj 不需要更换。

下载完成后执行 `.\start_8080_toolhub_stack.cmd restart` 切换。

---

## 6. 配置

复制 `.env.example` 为 `.env`，按需修改，启动脚本会自动加载。

常见调整：

**切换思考模式：**

```powershell
$env:THINK_MODE = 'think-off'; .\start_8080_toolhub_stack.cmd restart
```

**缩小上下文以节省显存：**

```powershell
$env:CTX_SIZE = '8192'; .\start_8080_toolhub_stack.cmd restart
```

**扩大文件系统可读范围：** 修改 `.env` 中的 `READONLY_FS_ROOTS`，多个目录用分号分隔。留空时默认只读项目目录。

修改后执行 `.\start_8080_toolhub_stack.cmd restart` 生效。

---

## 7. API 调用

网关兼容 OpenAI API 格式：

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-9B-Q4_K_M",
    "stream": true,
    "messages": [
      {"role": "user", "content": "今天有什么科技新闻？"}
    ]
  }'
```

支持 OpenAI API 的客户端可将 Base URL 设为 `http://127.0.0.1:8080/v1`。

---

## 其他入口

### WSL

WSL 入口复用 Windows 主链路，不会创建独立的 Linux 虚拟环境。

```bash
./install.sh                             # 安装
./start_8080_toolhub_stack.sh start      # 启动
```

服务管理命令与 Windows 一致，把 `.cmd` 换成 `.sh` 即可。

### Docker Compose

不需要在宿主机安装 Python 或手动下载模型。详见 [Docker Compose 文档](DOCKER_COMPOSE.md)。
