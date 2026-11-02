# 磁盘地图 DiskMap

SwiftUI + AppKit 原生 macOS 磁盘分析工具，中文界面。部署目标 macOS 14，Apple Silicon 优先；当前实际测试系统为 macOS 27.2，macOS 14 尚未实机验证。

## 功能

文件夹及常用目录扫描、后台渐进预览、嵌套矩形树图、筛选、排行、Finder 定位、取消扫描、重复内容检查、目录级历史快照。支持多选区域独立展示及过小项目合并展开，鼠标圈选已移除。工具与残留检查目前为只读预览，不能可靠判定卸载残留。

树图及排行主要采用文件已分配磁盘块（st_blocks × 512），详情保留逻辑大小。APFS 克隆和硬链接可能共享块，不代表独占容量或精确可释放空间。快照和重复检测仍以逻辑大小为口径。

扫描与重复检测只读。移入废纸篓需明确确认，会重检身份、路径及保护范围，仅普通文件可操作；不提供永久删除。检查与系统废纸篓调用不是对抗恶意并发替换的原子事务。

## 构建

```sh
xcodebuild -project DiskMap.xcodeproj -scheme DiskMap -configuration Release -derivedDataPath build ARCHS=arm64 build
open build/Build/Products/Release/磁盘地图.app
python3 Tests/run.py
python3 Tests/run_model.py
```

使用本地 ad-hoc 签名，无 Developer ID、无 Apple 公证。互联网下载后的 Gatekeeper 首次授权流程尚未验证，不建议关闭系统安全保护。

## 验证状态

核心及模型回归曾通过；近期多选、独立窗口、小项目合并等界面变更已编译，但尚未完成真实 GUI 验收。历史性能数据见 PERFORMANCE.md，其数值不代表最新版本已重新完成百万文件性能验收。该版本应标为预览版，不宣称公开稳定版。

完整源码、图标和自动化测试随工程提供。扫描路径元数据只保存在本机，不上传。应用没有自动遥测上传功能。
