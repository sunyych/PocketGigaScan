LumiaPocketGigaScan

Project: LumiaPocketGigaScan
Base: OpenPocketCine
Core dependency: lumia-gigascan-core
Initial hardware: DJI Pocket 2
Target hardware: DJI Pocket 4P
Type: New standalone application based on an upstream fork

1. Product Vision

Fork OpenPocketCine and evolve it into:

LumiaPocketGigaScan

定位不是另一个 DJI Mimo。

也不是单纯 Pocket Remote。

它是：

Programmable Robotic Gigapixel Camera built around DJI Pocket cameras.

目标：

DJI Pocket
     +
Phone
     +
LumiaPocketGigaScan
     ↓
Automated high-resolution scanning

不要求 Raspberry Pi。

不要求 ESP32。

第一目标架构：

DJI Pocket
    │
 BLE + Wi-Fi
    │
    ▼
Phone
    │
LumiaPocketGigaScan
    │
    ▼
lumia-gigascan-core
2. Upstream

Base project：

OpenPocketCine

Fork 为：

LumiaPocketGigaScan

必须保留 Apache-2.0 所要求的：

LICENSE
NOTICE
copyright attribution
3. Upstream Strategy

配置：

origin
→ LumiaPocketGigaScan

upstream
→ OpenPocketCine

原则：

尽量保持 Pocket protocol layer 接近 upstream。

不要为了 GigaScan 重写：

BLE
Wi-Fi
DUML
Live View
camera command
gimbal command

除非确实需要增加硬件支持。

这样以后可以继续获取 upstream：

Pocket 4 fixes
Pocket 4P fixes
firmware compatibility
DUML discoveries
4. Initial Hardware — Pocket 2

用户已经有 Pocket 2。

因此第一台实际开发设备：

DJI Pocket 2

第一阶段不是 Gigapixel。

第一阶段目标：

让 OpenPocketCine protocol architecture 支持 Pocket 2。

首先审计：

BLE discovery
pairing
Wi-Fi activation
Wi-Fi connection
DUML
gimbal
shutter
photo
preview
camera state

找出 Pocket 2 与 Pocket 3/4/4P 的差异。

5. Pocket Adapter

不要让 Scan Engine 直接调用 DUML。

建立：

PocketCamera

抽象，例如：

connect()
disconnect()

getCapabilities()

getPreview()

getGimbalPosition()

moveGimbal()

stopGimbal()

setZoom()

autofocus()

capturePhoto()

listMedia()

downloadMedia()

然后：

Pocket2Adapter
Pocket4Adapter
Pocket4PAdapter

可以共享大量底层 protocol code。

6. Capability Model

不要假设所有 Pocket 功能一样。

例如：

PocketCapabilities

supports_absolute_gimbal
supports_gimbal_feedback
supports_raw
supports_manual_focus
supports_tap_focus
supports_optical_tele
supports_photo_download
supports_builtin_panorama

这样 Pocket 2 和 4P 可以走不同路径。

7. Pocket 2 First Milestone

首先做到：

LumiaPocketGigaScan
        ↓
Pocket 2
        ↓
Connect
Preview
Gimbal
Capture

必须先完成这个闭环。

不要先写复杂 Stitch UI。

8. Existing Pocket 2 3×3 Panorama

Pocket 2 已经拥有内置 3×3 Panorama。

这个能力应该用于：

Reference Mode
Built-in Pocket 2
3×3 panorama

用于：

camera validation
gimbal validation
stitch quality comparison

但：

LumiaPocketGigaScan 的自定义扫描不能依赖 DJI 内置 3×3。

我们的目标仍然是：

Custom NxM
9. Custom 3×3

第一版自定义 scanner：

3 × 3

流程：

Scan Planner
     ↓
9 target positions
     ↓
Move gimbal
     ↓
settle
     ↓
focus
     ↓
capture
     ↓
next

Traversal：

1 → 2 → 3
        ↓
6 ← 5 ← 4
↓
7 → 8 → 9
10. Critical Requirement — Position Control

不能只实现：

joystick left/right/up/down

Scanner 必须获得可重复的：

target pan
target tilt

如果 Pocket protocol 支持 absolute position：

直接使用。

如果只有：

gimbal speed
+
position feedback

则实现 closed-loop software servo：

target
  ↓
position error
  ↓
velocity command
  ↓
feedback
  ↓
slow
  ↓
stop within tolerance

例如：

Target: 20.0°
Current: 14.2°

→ fast

Current: 18.8°

→ slow

Current: 19.95°

→ stop
11. Gimbal Accuracy Test

必须建立自动测试模式：

Center
↓
+10°
↓
Center
↓
-10°
↓
Center

重复例如：

20 cycles

测量：

mean error
max error
repeatability
settling time

因为 Gigapixel Scanner 真正需要的是：

repeatability，而不是云台看起来能动。

12. Integrate lumia-gigascan-core

LumiaPocketGigaScan 禁止复制 PTZ Manager stitch code。

必须使用 PRD-1：

lumia-gigascan-core

作为独立版本依赖。

关系：

LumiaPocketGigaScan
       │
       ├── Pocket protocol
       ├── Camera control
       ├── UI
       └── Capture
                │
                ▼
       lumia-gigascan-core
                │
                ├── ScanPlanner
                ├── geometry
                ├── stitching
                └── pyramid
13. Scan Workflow

用户进入：

GigaScan

看到 Wide Preview。

用户选择：

Scan Region

系统显示 Grid Overlay。

例如：

┌────────────────────────────┐
│                            │
│     ┌────┬────┬────┐       │
│     │ 1  │ 2  │ 3  │       │
│     ├────┼────┼────┤       │
│     │ 6  │ 5  │ 4  │       │
│     ├────┼────┼────┤       │
│     │ 7  │ 8  │ 9  │       │
│     └────┴────┴────┘       │
│                            │
└────────────────────────────┘

然后：

[ Start GigaScan ]
14. Scan Settings

至少支持：

Grid:
Auto
3×3
5×5
10×10
Custom

Overlap:
20%
25%
30%
35%
40%

Capture:
JPEG
RAW
RAW + JPEG

Focus:
Auto per tile

Capture count:
1
2
3

Capability 不支持的项目自动隐藏。

15. Sharpness Selection

如果：

Capture count = 3

则：

Tile
 ├── image 1
 ├── image 2
 └── image 3
       ↓
lumia-gigascan-core
       ↓
Sharpness analysis
       ↓
best image

避免：

AF miss
gimbal vibration
motion blur
16. Processing During Capture

Camera 在：

Tile 30

时：

Tile 27 → sharpness
Tile 26 → features
Tile 25 → matching

必须允许后台并行。

Capture priority 高于 Stitch。

不能因为手机正在 blend 一张大图导致云台扫描停十几秒。

17. Job Persistence

每次 Scan：

ScanJob

保存：

config
grid
tile states
camera metadata
image references
processing state

状态：

PLANNED
CAPTURING
PAUSED
PROCESSING
STITCHING
COMPLETED
FAILED
18. Resume

手机 App crash 或被系统杀掉后：

重新进入：

GigaScan 43

应该看到：

67 / 120 captured

[Resume]

已经成功保存的 RAW/JPEG 不重新拍。

19. Pocket 4P Target

Pocket 2 把系统开发完成以后：

第二个重要 Target：

DJI Pocket 4P

重点不是重新开发 Scan Engine。

而是增加：

Pocket4PAdapter

使：

connect
preview
gimbal
focus
capture
download

工作。

20. 60mm GigaScan

这是 LumiaPocketGigaScan 最重要的最终模式之一。

流程：

20mm wide camera
       ↓
Preview / compose
       ↓
Select ROI
       ↓
Switch 60mm tele
       ↓
Calculate HFOV/VFOV
       ↓
Generate dense grid
       ↓
Capture maximum-resolution stills
       ↓
Stitch

关键原则：

不要把 Digital Zoom 当成增加 GigaScan resolution。

优先使用真正的 60mm optical camera。

21. Maximum Resolution Capture

Pocket 4P 必须研究并选择：

maximum native still resolution

优先：

RAW/DNG

如果 Camera API/逆向协议允许。

每一个 Tile 尽可能保存：

original camera file

不要用：

Live Preview screenshot

作为 Gigapixel source。

22. Arbitrary NxM

Pocket 4P 最终不能限制：

3×3

目标：

3×3
5×5
10×10
20×20
NxM

真正限制因素应该是：

gimbal range
storage
battery
thermal
processing

而不是 UI 人为限制。

23. Panorama

同一 Scan Engine 可以产生：

Region Scan

Horizontal Panorama

Vertical Panorama

Wide Panorama

Maximum Gimbal Panorama

不要写不同 Scanner。

都是：

ScanPlan

的不同配置。

24. 360° Clarification

Pocket 云台机械范围如果不能真正完成：

360°

UI 不得宣传真正 360°。

显示：

Maximum Gimbal Panorama

未来如果增加 external rotation base，再扩展真正：

360 × 180
25. Stitching

所有拼接：

lumia-gigascan-core

负责。

LumiaPocketGigaScan 只提供：

image
pan
tilt
FOV
zoom/lens
row
column

Core 负责：

geometry initialization
feature matching
registration
warp
blend
output
26. GigaPixel Viewer

最终大图不能只：

save gigantic JPEG

目标支持：

Image Pyramid

App Viewer：

overview
 ↓
pinch zoom
 ↓
more detail
 ↓
more detail
 ↓
full-resolution tile

做到类似地图浏览。

27. Product UI

OpenPocketCine 原有 Remote 功能可以保留，但 LumiaPocketGigaScan 的主要导航逐渐调整为：

Camera

GigaScan

Panorama

Jobs

Gallery

Settings

不要第一阶段把 OpenPocketCine UI 全推倒重写。

28. Development Order

Codex 必须按下面顺序推进：

Fork OpenPocketCine
        ↓
Build upstream unchanged
        ↓
Pocket 2 connectivity
        ↓
Pocket 2 preview
        ↓
Pocket 2 gimbal
        ↓
Pocket 2 photo capture
        ↓
Gimbal repeatability
        ↓
Integrate lumia-gigascan-core
        ↓
Custom 3×3
        ↓
Stitch 3×3
        ↓
NxM
        ↓
Job resume
        ↓
Pocket 4P adapter
        ↓
60mm high-resolution scan
        ↓
Gigapixel viewer
29. Do Not Do

Codex 不应该：

× Rewrite OpenPocketCine protocol from scratch

× Copy Rust stitching into LumiaPocketGigaScan

× Couple lumia-gigascan-core to DJI

× Couple core to PTZ Manager

× Create monorepo

× Make Pi mandatory

× Make DJI built-in 3×3 the Scan Engine

× Use preview frames as final high-resolution tiles

× Assume Pocket 2 == Pocket 4P capabilities

× Implement huge UI redesign before Pocket 2 works
30. Acceptance Test — Pocket 2

第一阶段必须达到：

✓ app installs
✓ Pocket 2 connects
✓ preview works
✓ gimbal moves
✓ gimbal feedback works or equivalent closed-loop is available
✓ photo capture works
✓ custom 3×3 executes
✓ 9 source images preserved
✓ lumia-gigascan-core stitches them
✓ final image viewable

这就是第一个真正闭环。

31. Acceptance Test — Pocket 4P

后续：

✓ Pocket 4P connects
✓ 20mm preview
✓ 60mm camera selectable
✓ maximum-resolution still capture
✓ gimbal repeatability sufficient
✓ RAW/JPEG preserved
✓ custom NxM
✓ stitching
✓ output > native single-frame resolution

再做一个非常有意义的 Benchmark：

DJI Built-in Panorama
        VS
LumiaPocketGigaScan

比较：

resolution
detail
alignment
seams
dynamic range
processing time
32. Final Architecture

最终应该是非常干净的三个独立项目：

              lumia-gigascan-core
                 Rust / standalone
                   ▲         ▲
                   │         │
          ┌────────┘         └─────────┐
          │                            │
     PTZ Manager              LumiaPocketGigaScan
          │                            │
    ONVIF / VISCA                 DJI Pocket
    Generic PTZ              Pocket 2 → 4 → 4P

PTZ Manager 和 LumiaPocketGigaScan 之间没有 dependency。

两者唯一共享：

lumia-gigascan-core 的稳定公开 API。

这样以后你无论再接 Insta360 Luna Ultra、Sony PTZ，甚至自己做电动云台，都不需要再复制一次 Gigapixel 算法。
