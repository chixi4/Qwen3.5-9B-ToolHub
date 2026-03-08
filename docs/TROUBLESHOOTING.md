# 常见问题与排障

---

## 1. PowerShell 报脚本执行策略错误

看到 `PSSecurityException` 或 `about_Execution_Policies`，改用 `.cmd` 入口即可：

```powershell
.\install.cmd
.\start_8080_toolhub_stack.cmd start
```

如果一定要直接调用 `.ps1`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

---

## 2. 提示 llama-server.exe 不存在

重新执行安装脚本：

```powershell
.\install.cmd
```

完成后确认文件存在：`.tmp\llama_win_cuda\llama-server.exe`。

---

## 3. 提示模型文件不完整

检查以下两个文件是否存在且大小正常：

- `.env` 里 `MODEL_PATH` 指向的主模型文件，默认为 `Qwen3.5-9B-Q4_K_M.gguf`，执行过 Q8 安装则为 `Qwen3.5-9B-Q8_0.gguf`
- `.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\mmproj-Qwen3.5-9B-BF16.gguf`

文件残缺或为 0 字节时，删除后重新执行 `.\install.cmd`。

---

## 4. 启动后模型未就绪

```powershell
.\start_8080_toolhub_stack.cmd status
.\start_8080_toolhub_stack.cmd logs
```

首次启动需要 30–60 秒加载模型，刚启动不久的话稍等片刻。

---

## 5. 页面报内容编码错误

```powershell
.\start_8080_toolhub_stack.cmd restart
```

如果仍然出现，清浏览器缓存后刷新。

---

## 6. 显存不足

Q4_K_M 量化下模型加上视觉投影约占 6.1 GB 显存。如果显存紧张：

**缩小上下文窗口：**

```powershell
$env:CTX_SIZE = '8192'; .\start_8080_toolhub_stack.cmd restart
```

**降低图像 token 上限：**

```powershell
$env:IMAGE_MAX_TOKENS = '512'; .\start_8080_toolhub_stack.cmd restart
```

也可以直接修改 `.env` 里对应的值，然后重启。

---

## 7. 看不到回答下方的性能统计

重启服务后发一条新消息即可看到。旧消息不会回填统计数据。

---

## 8. WSL 相关

WSL 入口复用 Windows 主链路。如果 WSL 中找不到 `powershell.exe`，检查 WSL 配置中 `interop` 是否被禁用。

---

## 9. Docker Compose 相关

### 容器启动失败

确认 GPU 容器环境可用：

```bash
docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi
```

如果无法正常输出显卡信息，先解决 GPU 容器环境问题。

### 模型下载失败

容器首次启动时自动下载模型。下载失败时可通过 `.env` 覆盖 `MODEL_GGUF_URL` 和 `MODEL_MMPROJ_URL` 指向更快的源，再执行 `docker compose up --build`。

### 端口冲突

修改 `.env` 中的 `GATEWAY_PORT` 和 `BACKEND_PORT`，再重启容器。
