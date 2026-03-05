//! Trace Logger - JS 运行时追踪模块
//!
//! 通过环境变量启用:
//!   BUN_TRACE=1          启用追踪
//!   BUN_TRACE_FILE=path  输出文件路径
//!   BUN_TRACE_LEVEL=calls|state|full  追踪级别

const std = @import("std");
const bun = @import("bun");
const Environment = bun.Environment;

/// 追踪级别
pub const TraceLevel = enum(u8) {
    /// 只追踪函数调用
    calls = 1,
    /// 追踪调用 + 状态
    state = 2,
    /// 完整追踪
    full = 3,
};

/// 追踪配置
pub const TraceConfig = struct {
    enabled: bool = false,
    level: TraceLevel = .calls,
    output_file: ?[]const u8 = null,
    start_time: i128 = 0,
};

/// 追踪事件类型
pub const TraceEventType = enum(u8) {
    js_call = 1,
    js_return = 2,
    io_start = 3,
    io_end = 4,
    promise_create = 5,
    promise_resolve = 6,
    random_call = 7,
    date_now = 8,
    heap_snapshot = 9,
};

/// 追踪事件
pub const TraceEvent = struct {
    event_type: TraceEventType,
    timestamp: i64,
    mono_ns: i128,
    /// 函数名或操作名
    name: []const u8,
    /// 附加数据 (JSON)
    data: ?[]const u8 = null,
    /// 源码位置
    line: u32 = 0,
    column: u32 = 0,
    /// 文件名
    file: ?[]const u8 = null,
};

/// 全局追踪状态
var g_trace_state: ?TraceState = null;

const TraceState = struct {
    config: TraceConfig,
    events: std.ArrayList(TraceEvent),
    allocator: std.mem.Allocator,
    output_file: ?std.fs.File = null,
    lock: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator, config: TraceConfig) !TraceState {
        var state = TraceState{
            .config = config,
            .events = std.ArrayList(TraceEvent).initCapacity(allocator, 1024) catch .empty,
            .allocator = allocator,
        };

        // 尝试打开输出文件
        if (config.output_file) |path| {
            state.output_file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |err| blk: {
                bun.Output.print("[Trace] Failed to open output file: {s}\n", .{@errorName(err)});
                break :blk null;
            };
        }

        return state;
    }

    fn deinit(self: *TraceState) void {
        self.flush();
        self.events.deinit();
        if (self.output_file) |f| {
            f.close();
        }
    }

    fn log(self: *TraceState, event: TraceEvent) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.events.append(event) catch |err| {
            bun.Output.print("[Trace] Failed to log event: {s}\n", .{@errorName(err)});
        };

        // 每 1000 个事件刷新一次
        if (self.events.items.len % 1000 == 0) {
            self.flush();
        }
    }

    fn flush(self: *TraceState) void {
        if (self.events.items.len == 0) return;
        if (self.output_file == null) return;

        const file = self.output_file.?;
        const writer = file.writer();

        for (self.events.items) |event| {
            // JSON Lines 格式
            writer.print(
                \\{{"type":"{s}","ts":{},"mono":{},"name":"{s}","line":{},"column":{}}}
                \\
            , .{
                @tagName(event.event_type),
                event.timestamp,
                event.mono_ns,
                event.name,
                event.line,
                event.column,
            }) catch {};
        }

        self.events.clearRetainingCapacity();
    }
};

/// 初始化追踪系统
pub fn init(allocator: std.mem.Allocator) !void {
    if (g_trace_state != null) return;

    const trace_env = std.process.getEnvVarOwned(allocator, "BUN_TRACE") catch null;
    const enabled = trace_env != null and !std.mem.eql(u8, trace_env.?, "0");

    if (!enabled) return;

    var config = TraceConfig{
        .enabled = true,
        .start_time = std.time.nanoTimestamp(),
    };

    // 解析追踪级别
    if (std.process.getEnvVarOwned(allocator, "BUN_TRACE_LEVEL") catch null) |level| {
        config.level = if (std.mem.eql(u8, level, "state"))
            .state
        else if (std.mem.eql(u8, level, "full"))
            .full
        else
            .calls;
    }

    // 解析输出文件
    if (std.process.getEnvVarOwned(allocator, "BUN_TRACE_FILE") catch null) |path| {
        config.output_file = path;
    } else {
        config.output_file = "bun-trace.jsonl";
    }

    g_trace_state = try TraceState.init(allocator, config);

    bun.Output.print("[Trace] Enabled, level={s}, output={?s}\n", .{
        @tagName(config.level),
        config.output_file,
    });
}

/// 清理追踪系统
pub fn deinit() void {
    if (g_trace_state) |*state| {
        state.deinit();
        g_trace_state = null;
    }
}

/// 检查是否启用
pub fn isEnabled() bool {
    return g_trace_state != null and g_trace_state.?.config.enabled;
}

/// 获取追踪级别
pub fn getLevel() TraceLevel {
    return if (g_trace_state) |state| state.config.level else .calls;
}

/// 记录 JS 函数调用
pub fn logJsCall(
    func_name: []const u8,
    _: usize, // args_count - 保留供未来使用
    line: u32,
    column: u32,
) void {
    if (g_trace_state) |*state| {
        const event = TraceEvent{
            .event_type = .js_call,
            .timestamp = std.time.milliTimestamp(),
            .mono_ns = std.time.nanoTimestamp() - state.config.start_time,
            .name = func_name,
            .line = line,
            .column = column,
        };
        state.log(event);
    }
}

/// 记录 JS 函数返回
pub fn logJsReturn(
    func_name: []const u8,
    line: u32,
) void {
    if (g_trace_state) |*state| {
        const event = TraceEvent{
            .event_type = .js_return,
            .timestamp = std.time.milliTimestamp(),
            .mono_ns = std.time.nanoTimestamp() - state.config.start_time,
            .name = func_name,
            .line = line,
        };
        state.log(event);
    }
}

/// 记录 IO 操作开始
pub fn logIoStart(
    op_name: []const u8,
    details: ?[]const u8,
) void {
    if (g_trace_state) |*state| {
        const event = TraceEvent{
            .event_type = .io_start,
            .timestamp = std.time.milliTimestamp(),
            .mono_ns = std.time.nanoTimestamp() - state.config.start_time,
            .name = op_name,
            .data = details,
        };
        state.log(event);
    }
}

/// 记录 IO 操作结束
pub fn logIoEnd(
    op_name: []const u8,
    details: ?[]const u8,
) void {
    if (g_trace_state) |*state| {
        const event = TraceEvent{
            .event_type = .io_end,
            .timestamp = std.time.milliTimestamp(),
            .mono_ns = std.time.nanoTimestamp() - state.config.start_time,
            .name = op_name,
            .data = details,
        };
        state.log(event);
    }
}

/// 记录随机数调用
pub fn logRandomCall(value: f64) void {
    if (g_trace_state) |*state| {
        var buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
        const event = TraceEvent{
            .event_type = .random_call,
            .timestamp = std.time.milliTimestamp(),
            .mono_ns = std.time.nanoTimestamp() - state.config.start_time,
            .name = "Math.random",
            .data = str,
        };
        state.log(event);
    }
}

/// 记录 Date.now 调用
pub fn logDateNow(value: i64) void {
    if (g_trace_state) |*state| {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{}", .{value}) catch return;
        const event = TraceEvent{
            .event_type = .date_now,
            .timestamp = std.time.milliTimestamp(),
            .mono_ns = std.time.nanoTimestamp() - state.config.start_time,
            .name = "Date.now",
            .data = str,
        };
        state.log(event);
    }
}

/// 刷新并保存追踪数据
pub fn flush() void {
    if (g_trace_state) |*state| {
        state.flush();
    }
}
