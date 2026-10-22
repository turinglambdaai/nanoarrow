# nanoarrow

[English](README.md) · **中文**

[![CI](https://github.com/turinglambdaai/nanoarrow/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/nanoarrow/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

[Apache Arrow
nanoarrow](https://arrow.apache.org/nanoarrow/) 的 Racket FFI 绑定：读写包含原始类型
列的记录批次的 **Arrow IPC 文件与流**（`.arrow`）——纯 Racket 完成，无需安装
Arrow C++、pyarrow 或 JVM。

- Apache Arrow IPC **文件**格式（`ARROW1` magic + footer）与**流**格式，双向
  支持。
- 原始列类型：`bool`、`int8`–`int64`、`uint8`–`uint64`、
  `float32`/`float64`（Racket `flvector`）、`string`（UTF-8）。
- Writer 输出逐字节确定，并已对照 **pyarrow** 验证；reader 已对照
  pyarrow 生成的黄金样本验证。
- 其余一切（decimal、嵌套类型、timestamp 等）都会以清晰的
  "unsupported Arrow type" 错误失败，而不是崩溃。

## 状态

v0.1.0 —— 已文档化的限制：仅支持原始类型，每个载荷一个 record batch，
含 null 的列会被拒绝（可空性本身会经由 schema 往返保留），仅限
little-endian 主机，nanoarrow 0.9.x。

## 安装

```sh
raco pkg install --auto --link /path/to/nanoarrow
```

还需要 nanoarrow **0.9.x** 共享库（`libnanoarrow_shared` 与
`libnanoarrow_ipc_shared`）：

- **macOS**：`brew install nanoarrow`。加载器会自动探测
  `/opt/homebrew/opt/nanoarrow/lib`；设置 `DYLD_FALLBACK_LIBRARY_PATH`
  同样有效。
- **Linux**：从 `apache-arrow-nanoarrow-0.9.0` release 构建（小巧快速的
  CMake 构建）：

  ```sh
  cmake -S apache-arrow-nanoarrow-apache-arrow-nanoarrow-0.9.0 -B build \
        -DCMAKE_BUILD_TYPE=Release -DNANOARROW_BUILD_TESTS=OFF
  cmake --build build && cmake --install build --prefix ~/.nanoarrow
  ```

  然后通过 `LD_LIBRARY_PATH=~/.nanoarrow/lib` 或
  `NANOARROW_LIBRARY_DIR=~/.nanoarrow/lib` 暴露库路径。

`NANOARROW_LIBRARY_DIR`（若设置）会先于平台加载器被搜索；提供自动前缀
探测是因为 macOS 上的 `raco test` worker 不能可靠地继承 `DYLD_*` 变量。

## 用法

```racket
(require nanoarrow)

(define batch
  (record-batch
   3
   (list (arrow-field "name" 'string #t)
         (arrow-field "score" 'float64 #f)
         (arrow-field "count" 'int32 #t))
   (vector (vector "ada" "grace" "linus")
           (flvector 9.5 8.0 7.25)
           (vector 1 2 3))))

; encode to an Arrow IPC file payload (bytes)
(define file-bytes (record-batch->ipc-file batch))

; decode it back
(define batch-2 (ipc-file->record-batch file-bytes))
(vector-ref (record-batch-columns batch-2) 1) ; '#(9.5 8.0 7.25)

; write a real .arrow file
(with-output-to-file "example.arrow" #:exists 'truncate
  (lambda () (write-bytes file-bytes)))
```

流格式的对应函数：`record-batch->ipc-stream` /
`ipc-stream->record-batch`。

### 类型映射

| Arrow 类型 | Symbol | Racket |
|---|---|---|
| boolean | `'bool` | `(vectorof boolean?)` |
| int8/int16/int32/int64 | `'int8` … | `(vectorof exact-integer?)` |
| uint8/uint16/uint32/uint64 | `'uint8` … | `(vectorof exact-integer?)` |
| float (32 位) | `'float32` | `flvector?` |
| double (64 位) | `'float64` | `flvector?` |
| string (utf8) | `'string` | `(vectorof string?)` |

完整文档：`raco docs nanoarrow`（或
`nanoarrow/scribblings/nanoarrow.scrbl`）。

## 互操作测试

提交在仓库中的测试套件无需 pyarrow 即可运行：

```sh
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/nanoarrow/lib raco test -p nanoarrow
```

覆盖内容：

1. **Reader 黄金样本**——pyarrow 写出的 `.arrow` 文件
   （`test/data/golden-*.arrow`）解码为固定的 Racket 值
   （`test/data/expected.rkt`），包括负整数、unicode 字符串、空的
   0 行批次以及单列批次。
2. **Writer 验证**——我们的 writer 对混合批次产出的字节已提交在仓库
   中（`test/data/writer-output-*`），并经 pyarrow 20.0.0 解码并做值校验
   （`test/interop/validate-writer.py`）；测试套件断言字节一致，回归会
   显式失败。CI 不需要 pyarrow。
3. **往返测试**——用我们的 reader 读取我们 writer 的输出，逐类型覆盖，
   外加空批次与单列批次两个边界情况。
4. **错误处理**——错误的 magic、截断的文件/流、不支持的列类型
   （decimal/list 黄金样本）、null、越界整数、列长度不匹配：全部给出
   清晰的 `exn:fail` 消息。

重新生成测试夹具或重跑 pyarrow 验证见
`test/interop/README.md`（仅构建期需要）。

## 设计说明

- FFI 层（`nanoarrow/private/ffi.rkt`）显式声明 0.9.0 头文件中的每个
  C 结构体，并在测试套件中固定其大小；加载器按若干知名前缀依次回退。
- reader 使用 nanoarrow 的 IPC 解码器（`ArrowIpcDecoder*`），带完整的
  flatbuffer 校验，因此损坏的输入不会导致越界读取；解码出的数组持有
  自己的缓冲区（decoder 从输入中拷贝出来）。
- writer 通过 nanoarrow 构建 schema（`ArrowSchema*`），并向 IPC 编码器
  （`ArrowIpcWriter`）喂入手工填充的 `ArrowArrayView`，其缓冲区视图直接
  指向 Racket 字节串——零拷贝，写路径上没有 C 侧的缓冲区管理。
- 所有 C 资源在每条路径上都通过 `dynamic-wind` 释放。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
