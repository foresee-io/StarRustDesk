# HDR 视频支持

本轮仅增加控制端能力，不修改远端 RustDesk 的采集/编码协议，不伪造 HDR 内容。

## 路径

- H.264、H.265、VP9、AV1 系统解码：读取输出格式中的色彩原色、传递函数、矩阵、范围及 HDR Vivid 标记。PQ（16）/HLG（18）才判定 HDR；10 位或 BT.2020 本身不等于 HDR。
- Surface 不再提前强制 BGRA8888；由解码器选择原生格式。CPU 解码切到系统解码时先清除旧窗口的 8 位格式约束。已确认的 BT.2020 PQ/HLG 写入 NativeWindow 色彩空间，交由系统合成器显示。不会把整个应用界面强行改为 HDR。
- 查询主窗口实际所在显示器的 HDR 格式，单独投屏时使用外接屏能力。相应格式支持且真实输出缓冲区至少 10 位时显示 `HDR10/PQ · Surface` 或 `HLG · Surface`，表示已接入原生输出路径，不代表测量确认了屏幕亮度。
- 不支持/无法确认 HDR 显示能力时显示“系统适配”，由系统合成器处理；这不等于已验证 HDR→SDR 转换成功。色彩空间设置失败显示“输出不支持”，不能冒充 HDR 输出。
- AV1 软件解码：读取 libaom 的实际 CICP/位深；PQ/HLG 按传递函数转换到线性亮度，再进行 BT.2020→BT.709 和亮度保持的 extended Reinhard 映射，最后转换 sRGB/BGRA8888。显示 `HDR10/PQ → SDR` / `HLG → SDR`。
- 软件高位深平面转换支持 8/10/12 位、4:2:0/4:2:2/4:4:4、单色及行填充；不支持的矩阵（例如 ICtCp/BT.2020 CL）明确拒绝，避免颜色错误。
- VP9 裸流没有 PQ/HLG 传递函数字段。仅有 10 位/BT.2020 时显示“未标记”，不猜测其为 HDR，也不盲目色调映射。

## 生命周期与诊断

解码器切换/会话重置清除色彩状态；旧解码回调通过实例检查丢弃；旋转重新绑定 Surface 后重新设置色彩空间。CPU 渲染会恢复 sRGB/BGRA8888，避免上一条 HDR 连接污染下一条 SDR。

监控面板新增“动态范围”。`video-color` 日志仅在色彩状态变化时记录原色、传递函数、矩阵、范围、位深和输出路径；`video-health` 周期摘要记录动态范围和路径。读取解码输出 NativeBuffer 的真实 P010/RGBA1010102 格式以及色彩标记，并正确释放借出的引用。无法读取真实位深的 opaque Surface 保持位深未知，不用 Main10 profile 冒充实际 10 位输出。格式变化回调不等待解码器锁，锁忙时在下一次输出补读，避免 Configure/Stop 内回调造成等待死锁。

## 限制和验收

远端把 HDR 捕获转为 SDR/8 位之后，控制端不能恢复 HDR。当前 RustDesk protobuf 没有专门的 HDR 能力协商字段，因此连接 HDR 桌面并不保证收到 HDR 视频。

软件映射采用静态参考白 203 nit、PQ 10000 nit / HLG 1000 nit 名义峰值，不实现 HDR10+/Dolby Vision 动态元数据，也不伪造 HDR Vivid 元数据。不对所有输入设置只适用于 HDR Vivid 的解码器输出色彩转换选项。

代码/构建测试不能代替真机验收：需要远端真实 PQ/HLG 视频源分别验证 HDR 手机/平板、SDR 外接屏、旋转、重连、HDR→SDR 切换和亮暗细节。尤其系统解码在 SDR 屏上的色调映射取决于设备合成器，必须实测；本轮不声称完整远端 HDR 采集链路已验证。

参考：Huawei HDR Vivid 转 SDR 指导、SDK NativeWindow 色彩空间 API、display.hdrFormats、libaom CICP。

本地回归：`tools/test-hdr-video.cjs` 编译并运行真实 C++ 转换测试，同时检查 UI、元数据与会话隔离。
