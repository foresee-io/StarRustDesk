# 高清与自定义码率

入口：新建或编辑连接 → 更多选项 → 连接模式。

- 高清优先：使用 RustDesk `ImageQuality::Best`，目标 30 FPS。
- 自定义：码率比例 10%～2000%，目标帧率 5～120 FPS，初始值 100% / 30 FPS。
- 不改变原有四种模式和默认“高流畅”。更高参数不保证实际帧率或清晰度，且会增加带宽、耗电和拥塞风险。
- 参数随已保存连接保留，沿用 `performancePreset` 字段，格式 `custom:<比例>:<帧率>`，兼容现有加密备份与云同步；旧版本可能回退至默认模式。
- 参数在下一次连接时生效。百分比不是固定 Mbps，可在连接信息里观察实际速度和目标码率。
- 官方公共服务器且非直连时，自定义比例超过 100% 回退至 50%，目标帧率限制为 30 FPS；自建服务器或直连保持所选参数。后台降至 2 FPS/低画质，回到前台恢复所选模式。

协议对照：官方 `src/client.rs` 的 `get_option_message` 与 `save_custom_image_quality`，使用 `custom_image_quality = percent << 8`、`custom_fps`，自定义时 `image_quality` 为 `NotSet`。登录、性能选项重发、后台恢复与 VP9 回退路径均携带该字段。

参考：https://github.com/rustdesk/rustdesk/blob/master/src/client.rs
