# TROUBLESHOOTING

## 1. 页面报内容编码错误

执行重启：

```powershell
.\start_8080_toolhub_stack.cmd restart
```

如果仍失败，先清浏览器缓存，再刷新页面。

## 2. 启动后模型未就绪

先看状态：

```powershell
.\start_8080_toolhub_stack.cmd status
```

再看日志：

```powershell
.\start_8080_toolhub_stack.cmd logs
```

## 3. 提示缺少 llama-server.exe

重新执行安装脚本，确保 `.tmp\llama_win_cuda\llama-server.exe` 存在。

## 4. 提示模型文件不完整

检查下面两个文件是否存在：

- `.env` 里的 `MODEL_PATH` 指向的主模型文件，默认是 `.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\Qwen3.5-9B-Q4_K_M.gguf`，执行 `.\install_q8.cmd` 后会变成 `Qwen3.5-9B-Q8_0.gguf`
- `.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\mmproj-Qwen3.5-9B-BF16.gguf`

## 5. 看不到回答下方性能统计

当前版本要求消息里存在 `timings.predicted_n` 和 `timings.predicted_ms`。

重启后发一条新消息再看，旧消息不会回填。

## 6. 需要走 WSL 兼容流程

WSL 入口会直接复用 Windows 安装和启动链路，不会再单独创建 Linux 虚拟环境。

```powershell
.\install.cmd -Wsl
```

然后在 WSL 内执行：

```bash
./install.sh
./start_8080_toolhub_stack.sh start
```

## 7. PowerShell 报脚本执行策略错误

如果看到 `PSSecurityException` 或 `about_Execution_Policies`，不要直接执行 `.ps1`，改用下面命令：

```powershell
.\install.cmd
.\start_8080_toolhub_stack.cmd start
```

如果你必须调用 `.ps1`，请显式带上 Bypass：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```
