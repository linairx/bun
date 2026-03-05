# Bun Trace - 带追踪功能的 Bun 运行时

基于 [Bun](https://github.com/oven-sh/bun) 修改，添加 JS 运行时追踪功能。

## 功能

- **JS 函数调用追踪**: 记录所有 JS 函数的调用和返回
- **非确定性操作记录**: Math.random, Date.now 等
- **JSON Lines 输出**: 便于分析和回放

## 使用方法

### 1. 编译

```bash
# 安装依赖
# Ubuntu/Debian:
sudo apt install cmake ninja-build pkg-config libssl-dev zlib1g-dev

# macOS:
brew install cmake ninja pkg-config openssl zlib

# 编译
cd bun-trace
bun install
bun run build
```

### 2. 运行

```bash
# 启用追踪
BUN_TRACE=1 ./bun your-script.js

# 指定输出文件
BUN_TRACE=1 BUN_TRACE_FILE=trace.jsonl ./bun your-script.js

# 指定追踪级别
BUN_TRACE=1 BUN_TRACE_LEVEL=full ./bun your-script.js
```

### 3. 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `BUN_TRACE` | 启用追踪 (设为 1) | 未启用 |
| `BUN_TRACE_FILE` | 输出文件路径 | `bun-trace.jsonl` |
| `BUN_TRACE_LEVEL` | 追踪级别 | `calls` |

追踪级别:
- `calls`: 只追踪函数调用
- `state`: 追踪调用 + 状态变化
- `full`: 完整追踪（包括堆快照）

### 4. 输出格式

输出为 JSON Lines 格式，每行一个 JSON 对象：

```json
{"type":"js_call","ts":1234567890,"mono":1000,"name":"main","line":1,"column":0}
{"type":"js_return","ts":1234567891,"mono":1001,"name":"main","line":5}
{"type":"random_call","ts":1234567892,"mono":1002,"name":"Math.random","data":"0.123456"}
{"type":"date_now","ts":1234567893,"mono":1003,"name":"Date.now","data":"1234567890123"}
```

### 5. 分析追踪数据

```bash
# 统计事件类型
jq -r '.type' trace.jsonl | sort | uniq -c

# 提取所有函数调用
jq 'select(.type == "js_call")' trace.jsonl

# 查看特定函数的调用
jq 'select(.name == "fetch")' trace.jsonl
```

## 与 sandbox-record 集成

可以与 sandbox-record 结合使用，实现完整的录制回放：

```bash
# 系统级 + JS 级追踪
sandbox-record --trace strace -- \
  env BUN_TRACE=1 ./bun-trace your-script.js
```

## 修改的文件

| 文件 | 修改内容 |
|------|---------|
| `src/trace_logger.zig` | 新增：追踪模块 |
| `src/bun.zig` | 添加 trace_logger 导出 |
| `src/cli.zig` | 添加追踪初始化 |
| `src/bun.js/bindings/JSValue.zig` | 添加函数调用追踪 |

## 回放功能（计划中）

未来将支持基于追踪数据的确定性回放：

```bash
# 录制
BUN_TRACE=1 BUN_TRACE_LEVEL=full ./bun script.js

# 回放
bun-replay trace.jsonl --step 100  # 跳到第 100 个事件
bun-replay trace.jsonl --inspect   # 进入调试模式
```

## 许可证

与 Bun 相同，使用 MIT 许可证。
