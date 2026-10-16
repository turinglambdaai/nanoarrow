# AGENTS.md

Apache Arrow nanoarrow C 库的 Racket FFI 绑定（MIT，已上架 Racket catalog）。

## 结构

Multi-collection 包：collection 即 `nanoarrow/` 子目录，scribblings 声明在 `nanoarrow/info.rkt`（collection 级）；`test/` 在包内。

## 常用命令

```bash
# 原生库须从源码构建（Homebrew formula 关闭了测试所需的 IPC 模块，CI 同款）
# 构建产物装到 ~/.nanoarrow，并设：
export DYLD_FALLBACK_LIBRARY_PATH="$HOME/.nanoarrow/lib"   # macOS
export LD_LIBRARY_PATH="$HOME/.nanoarrow/lib"              # Linux
raco pkg install --auto --link "$(pwd)"
raco test nanoarrow/test/nanoarrow-test.rkt
```

## 验证与发版

- CI（`ci.yml`）：源码构建 nanoarrow 0.9.0 → 设库路径 → 安装包 → 显式路径跑测试。
- 发版 = tag `v<版本>` + CHANGELOG 同步；catalog 侧为手动提交（pkgd）。

## 仓库特定规矩

- **链接的包目录内不得有杂散子目录**（构建产物、下载缓存等）——raco setup 会把它们当 collection 扫描；原生构建一律放包外（CI 用 mktemp）。
