# QUICKSTART

## 1. 安装

### Windows 主入口

在项目根目录双击运行 `bootstrap.bat`。

### PowerShell 手动入口

```powershell
.\install.cmd
```

### WSL 兼容入口

WSL 入口会直接复用 Windows 安装主脚本，和 `cmd`、PowerShell 保持一致。

```powershell
.\install.cmd -Wsl
```

如果已经在 WSL shell 里，也可以直接执行：

```bash
./install.sh
```

## 2. 启动

```powershell
.\start_8080_toolhub_stack.cmd start
```

## 3. 打开网页

浏览器访问 `http://127.0.0.1:8080`

## 4. 查看状态

```powershell
.\start_8080_toolhub_stack.cmd status
```

## 5. 查看日志

```powershell
.\start_8080_toolhub_stack.cmd logs
```

## 6. 停止服务

```powershell
.\start_8080_toolhub_stack.cmd stop
```

## 7. WSL 直接入口

```bash
./start_8080_toolhub_stack.sh start
./start_8080_toolhub_stack.sh stop
```
