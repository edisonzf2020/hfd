# hfd

一个围绕 **`hfd.sh`** 的轻量级下载工具集，用于**安全、可控地下载 Hugging Face 模型**，同时支持：

* **单模型后台下载**
* **多模型串行批量后台下载**

本仓库主要解决以下问题：

* `hfd.sh` 内部使用 **aria2 多线程下载**
* 多个 `hfd.sh` 并行运行时，极易导致磁盘 / 网络 / FD 资源被打爆
* 需要**明确区分**「单独下载」和「批量串行下载」两种使用方式

---

## 1. `hfd.sh`

`hfd.sh` 是本仓库中**唯一的实际下载程序**。

`hfd.sh` **来自以下 gist**，本仓库并未对其整体逻辑进行修改：

[https://gist.github.com/padeoe/697678ab8e528b85a2a7bddafea1fa4f](https://gist.github.com/padeoe/697678ab8e528b85a2a7bddafea1fa4f)

本仓库**唯一做的修改**是：

```bash
# HF_ENDPOINT=${HF_ENDPOINT:-"https://huggingface.co"}
HF_ENDPOINT=${HF_ENDPOINT:-"https://hf-mirror.com"}
```

即：

* 保留通过环境变量覆盖 `HF_ENDPOINT` 的能力
* 将**默认下载源**从官方 Hugging Face 改为 `hf-mirror.com`

除此之外，`hfd.sh` 与原 gist **完全一致**。

---

## 2. Wrapper 脚本说明

本仓库提供了 **两种明确区分的使用模式**，用于不同场景。

---

### 2.1 `hfd_wrapper.sh` —— 非阻塞（单模型）

**适用场景：**

* 只下载 **一个模型**
* 希望下载在 **后台运行**
* 不关心下载何时完成

**行为特征：**

* 内部使用 `nohup` 启动 `./hfd.sh`
* 脚本立即返回
* 适合临时、手动下载

**目录与日志约定：**

> **注意**：请根据个人环境修改以下路径变量。若目录不存在，脚本将自动创建。

  ```bash
  BASE_MODEL_DIR="$HOME/data/models/shared"
  BASE_LOG_DIR="$HOME/playground/hfd/logs"
  ```

**示例：**

```bash
./hfd_wrapper.sh Qwen/Qwen3-30B-A3B-Instruct-2507
```

---

### 2.2 `hfd_wrapper_blocking.sh` —— 阻塞（单模型）

**适用场景：**

* 调用方必须等待下载完成
* 被其他控制脚本（如 batch）调用

**行为特征：**

* 前台运行 `./hfd.sh`
* **不会后台化**
* 只有下载完成后才退出

**目录与日志约定：**

> **注意**：请根据个人环境修改以下路径变量。若目录不存在，脚本将自动创建。

  ```bash
  BASE_MODEL_DIR="$HOME/data/models/shared"
  BASE_LOG_DIR="$HOME/playground/hfd/logs"
  ```

* 与 `hfd_wrapper.sh` 使用**完全一致的使用规范**

> ⚠️ 该脚本的设计目标是：**“只要脚本返回，就代表该模型已经完整下载结束”**

---

### 2.3 `hfd_batch.sh` —— 串行批量下载控制器

**适用场景：**

* 需要下载 **多个模型**
* 必须保证 **一次只下载一个模型**
* 避免多个 `aria2` 同时运行

**行为特征：**

* 从列表文件逐行读取模型
* 对每一行调用 `hfd_wrapper_blocking.sh`
* 等当前模型下载完成后，才启动下一个

**典型用法：**

```bash
nohup ./hfd_batch.sh batch_list.txt > hfd_batch.log 2>&1 &
```

---

## 为什么 batch 一定要使用 blocking wrapper

这是本仓库设计中**最关键的一点**。

### 1️⃣ `hfd.sh` 内部已经是“并行下载”

* `hfd.sh` 使用 `aria2`
* 默认启用多连接、多文件并发
* **单个模型下载本身就已经是高并发任务**

### 2️⃣ 非阻塞 wrapper 会立刻返回

如果在 batch 中使用 `hfd_wrapper.sh`（非阻塞）：

```text
启动模型 A（返回）
启动模型 B（返回）
启动模型 C（返回）
```

结果是：

* 同时运行多个 `hfd.sh`
* 每个 `hfd.sh` 再启动一组 `aria2`
* 实际效果是：

> **N × aria2 并发 × 多连接 = 灾难**

常见后果包括：

* 磁盘 IO 被打满
* 网络连接数爆炸
* 下载速度反而显著下降
* aria2 / git / Python 进程失控

### 3️⃣ blocking wrapper 是唯一可靠的串行控制点

`hfd_wrapper_blocking.sh` 的语义非常明确：

> **“脚本未返回 = 当前模型仍在下载”**

batch 的控制逻辑因此变成：

```text
下载模型 A（等待完成）
下载模型 B（等待完成）
下载模型 C（等待完成）
```

这样可以保证：

* 系统中任意时刻 **只有一个 `hfd.sh` 在运行**
* `aria2` 的并发完全由 `hfd.sh` 内部控制
* 带宽 / IO / FD 都是可预测、可控的

### 4️⃣ 结论（设计约束）

> **batch 场景下：**
>
> * `hfd_wrapper_blocking.sh` 是 *必须的*
> * `hfd_wrapper.sh` 是 *明确禁止的*
>
> 这是为了稳定性，而不是“实现偏好”。

---

## 3. `batch_list.txt` 写法说明

`batch_list.txt` 用于定义批量下载的模型列表。

### 规则

* 一行一个模型
* 格式：`org_name/repo_name`
* 空行会被忽略
* 以 `#` 开头的行视为注释

### 示例

```text
# =========================
# Qwen 30B A3B 系列
# =========================
Qwen/Qwen3-30B-A3B-Thinking-2507
Qwen/Qwen3-30B-A3B-Instruct-2507-FP8
Qwen/Qwen3-30B-A3B-Instruct-2507

# Dense 模型
Qwen/Qwen3-32B
Qwen/Qwen3-14B
```

> ⚠️ 默认不支持行尾注释（repo 名后再写 `# ...`）

---

## 4. 故障排查与进程管理

由于 `hfd.sh` 内部使用 **aria2**，下载异常时需要手动检查进程状态。

---

### 4.1 查看下载进程

#### 查看 `hfd.sh`

```bash
ps -ef | grep hfd.sh | grep -v grep
```

有输出说明仍有下载任务在运行。

#### 查看 `aria2`

```bash
ps -ef | grep aria2 | grep -v grep
```

即使 `hfd.sh` 已退出，`aria2` 也**可能仍在后台运行**。

---

### 4.2 安全终止下载

#### 推荐：终止所有 `hfd.sh`

```bash
pkill -f hfd.sh
```

#### 若 `aria2` 仍存在

```bash
pkill -f aria2c
```

这是安全的：

* 已下载文件不会损坏
* 未完成部分支持断点续传

---

### 4.3 常见错误场景

**现象：**

* 多个模型同时下载
* 磁盘 / 网络负载异常

**原因：**

* 在 batch 场景中误用了 `hfd_wrapper.sh`（非阻塞）

**解决方案：**

* 终止所有 `hfd.sh` / `aria2`
* batch 只使用 `hfd_wrapper_blocking.sh`

---

## 5. 使用方式总结

| 使用场景     | 推荐脚本                      |
| -------- | ------------------------- |
| 单模型，后台下载 | `hfd_wrapper.sh`          |
| 单模型，等待完成 | `hfd_wrapper_blocking.sh` |
| 多模型，串行批量 | `hfd_batch.sh`            |

---

## License

MIT
