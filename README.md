# SwallowCalendar

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0%2B-blue" alt="macOS">
  <img src="https://img.shields.io/badge/Swift-5.9-orange" alt="Swift">
  <img src="https://img.shields.io/github/license/Qithking/SwallowCalendar" alt="License">
  <img src="https://img.shields.io/github/v/release/Qithking/SwallowCalendar" alt="Release">
</p>

<p align="center">
  <strong>燕子日历</strong> - 一款简洁优雅的 macOS 菜单栏日历应用
</p>

<p align="center">
  <img src="https://img.shields.io/badge/功能丰富-日历%20%E2%80%A2%20农历%20%E2%80%A2%20节假日-0099FF?style=flat-square" alt="功能">
</p>

---

## 功能特性

### 📅 日历功能
- **月历视图** - 直观的月份日历展示
- **日期选择** - 快速定位任意日期
- **农历显示** - 支持农历日期展示
- **节假日标注** - 自动显示节假日信息

### 🎨 主题定制
- **自定义主题色** - 随心所欲切换应用配色
- **菜单栏图标样式** - 多种图标风格可选（实心日期、描边日期、日历图标）

### 📝 待办事项
- **快速添加** - 自然语言输入，智能识别时间和优先级
- **事件管理** - 创建、编辑、删除日程事件
- **提醒功能** - 自定义提醒时间
- **循环任务** - 支持每日、每周、每月、每年循环

### 🔗 数据同步
- **系统日历集成** - 与 macOS 系统日历无缝同步
- **ICS 订阅** - 支持订阅外部 ICS 日历（节假日日历等）
- **本地缓存** - 事件数据本地缓存，快速响应

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统版本 | macOS 13.0 (Ventura) 及以上 |
| 架构 | Apple Silicon / Intel |

---

## 安装方式

### Homebrew (推荐)

```bash
brew install --cask swallowcalendar
```

### 手动安装

1. 从 [Releases](https://github.com/Qithking/SwallowCalendar/releases) 下载最新版本
2. 解压 `.dmg` 文件
3. 将应用拖入 `应用程序` 文件夹

---

## 使用说明

### 快速添加待办

在输入框中输入自然语言即可快速创建待办事项：

```
明天上午10点开会           → 创建明天的会议日程
下午3点交报告 重要          → 创建带优先级的事件
每周一晨会 每天循环        → 创建循环事件
```

### 支持的指令关键词

| 类型 | 关键词 |
|------|--------|
| 日期 | 今天、明天、后天、本周、下周 |
| 时间 | 上午、下午、早上、晚上 |
| 优先级 | 重要、高、中、低 |
| 循环 | 每天、每周、每月、每年 |
| 颜色 | 红色、蓝色、绿色等 |

---

## 技术架构

```
SwallowCalendar/
├── Models/          # 数据模型
├── Services/        # 核心服务
│   ├── CalendarService.swift      # 日历服务
│   ├── ICSService.swift           # ICS 解析服务
│   ├── NLPTaskParser.swift         # 自然语言解析
│   └── AppSettings.swift           # 设置管理
├── Views/           # 界面视图
│   ├── Calendar/    # 日历相关视图
│   ├── Events/      # 事件相关视图
│   └── Settings/    # 设置页面
└── Utils/          # 工具函数
```

---

## 开发相关

### 环境要求

- Xcode 15.0+
- Swift 5.9+
- macOS SDK 13.0+

### 编译运行

```bash
# 克隆项目
git clone https://github.com/Qithking/SwallowCalendar.git

# 进入项目目录
cd SwallowCalendar

# 使用 Xcode 打开
open SwallowCalendar.xcodeproj

# 在 Xcode 中编译运行 (⌘+R)
```

### 主要依赖

- **SwiftUI** - 用户界面框架
- **SwiftData** - 数据持久化
- **EventKit** - 系统日历集成

---

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘ + ,` | 打开设置 |

---

## 更新日志

详细更新日志请查看 [CHANGELOG.md](./CHANGELOG.md)

### 最近更新

- ✨ 主题色自定义支持
- 🎨 优化的选中日期样式
- 📱 窗口自由缩放

---

## 贡献指南

欢迎提交 Issue 和 Pull Request！

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 创建 Pull Request

---

## 许可证

本项目基于 [GPLv3 License](./LICENSE) 开源。

---

## 联系方式

- **GitHub**: [Qithking/SwallowCalendar](https://github.com/Qithking/SwallowCalendar)
- **作者**: [Qithking](https://github.com/thking)

---

<p align="center">
  <sub>如果你觉得这个项目对你有帮助，请不要忘记 ⭐️</sub>
</p>
