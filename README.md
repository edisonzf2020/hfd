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

本仓库做的修改有三处。

第一处，修改默认下载源：

```bash
# HF_ENDPOINT=${HF_ENDPOINT:-"https://huggingface.co"}
HF_ENDPOINT=${HF_ENDPOINT:-"https://hf-mirror.com"}
```

即：

* 保留通过环境变量覆盖 `HF_ENDPOINT` 的能力
* 将**默认下载源**从官方 Hugging Face 改为 `hf-mirror.com`

第二处，新增 `--include-dir` / `--exclude-dir` 参数，按目录（相对仓库根）筛选文件，可跟多个目录：

```bash
./hfd.sh stabilityai/stable-diffusion-xl-base-1.0 --include-dir vae unet --exclude-dir text_encoder_2
```

* 目录只匹配仓库根下的路径前缀，例如 `--include-dir vae` 匹配 `vae/a.bin`，不匹配 `x/vae/c.bin`
* 可与 `--include` / `--exclude` 组合使用，include 类条件取并集，exclude 类条件同理

第三处，新增 `--retries` / `--retry-wait` 参数，统一控制 aria2c 和 wget 的重试：

* `--retries N`：每个文件的尝试次数，`0` 为无限（默认 `0`），对应 aria2c `--max-tries` / wget `--tries`
* `--retry-wait S`：重试间隔秒数，范围 0-600（默认 `5`），对应 aria2c `--retry-wait` / wget `--waitretry`（wget 按 1..S 秒递增等待）
* 使用 wget 时固定加 `--retry-connrefused`，连接被拒绝也重试，与 aria2c 一致
* 这两个参数只影响下载阶段，修改后重复运行不会重建文件列表

除此之外，`hfd.sh` 与原 gist **完全一致**。

---

## 2. `ghd.sh`

`ghd.sh` 是 `hfd.sh` 的 GitHub 版本：结构、参数和断点续传方式与 `hfd.sh` 相同，下载 GitHub 仓库在某个分支 / tag / commit 下的文件（不含 git 历史）。依赖同样是 `curl` + `aria2c` 或 `wget`，`jq` 可选（未安装时用 grep/awk 解析，较慢）。

**用法：**

```bash
./ghd.sh <owner/repo> [--include ...] [--exclude ...] [--include-dir ...] [--exclude-dir ...] \
         [--token tok] [--tool aria2c|wget] [-x n] [-j n] [--retries n] [--retry-wait sec] \
         [--local-dir path] [--revision ref]
```

* `--include` / `--exclude` / `--include-dir` / `--exclude-dir` 的语义与 `hfd.sh` 完全一致
* `--retries N`（默认 `0` 即无限，对应 aria2c `--max-tries` / wget `--tries`）和 `--retry-wait S`（0-600，默认 `5`，对应 aria2c `--retry-wait` / wget `--waitretry`）与 `hfd.sh` 相同，wget 同样固定加 `--retry-connrefused`；修改它们不会重新获取文件树
* `--revision` 默认 `HEAD`（即默认分支），可为分支、tag 或 commit
* `--local-dir` 默认为仓库名；文件列表等元数据缓存在 `<local-dir>/.ghd/`，命令参数不变时重复运行即续传 / 跳过已完成文件

**示例：**

```bash
./ghd.sh octocat/Spoon-Knife
./ghd.sh octocat/Spoon-Knife --revision test-branch --tool wget
./ghd.sh edisonzf2020/ChinaTextbook --include-dir 小学 --exclude *.md
./ghd.sh myorg/private-repo --token mytoken
```

**环境变量：**

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GITHUB_TOKEN` | 无 | 未传 `--token` 时使用；有 token 时 API 请求和下载都带 `Authorization` 头 |
| `GITHUB_API` | `https://api.github.com` | 获取文件列表（`/repos/<repo>/git/trees/<ref>?recursive=1`） |
| `GITHUB_RAW` | `https://raw.githubusercontent.com` | 下载文件（`<GITHUB_RAW>/<repo>/<ref>/<path>`） |

`GITHUB_API` / `GITHUB_RAW` 可改为代理或镜像地址，例如在国内网络环境下使用。

**限制：**

* **Git LFS**：`raw.githubusercontent.com` 对 LFS 文件只返回 pointer 文本（`version https://git-lfs.github.com/spec/v1 ...`）。`media.githubusercontent.com/media/<repo>/<ref>/<path>` 能返回 LFS 实际内容，但对普通文件返回 404，所以不能统一使用。需要 LFS 内容时，可在下载完成后对 pointer 文件补下载（路径含特殊字符时需自行 URL 编码）：

  ```bash
  cd <local-dir>
  grep -rlI --exclude-dir=.ghd '^version https://git-lfs.github.com/spec/v1' . | while IFS= read -r f; do
      f=${f#./}; curl -fsSL -o "$f" "https://media.githubusercontent.com/media/<owner>/<repo>/<ref>/$f"
  done
  ```

* 未登录时 GitHub API 限额为每小时 60 次；每次生成文件列表消耗 1 次，续传不消耗
* 文件数超过 100,000（或树数据超过 7 MB）时 GitHub 会截断文件列表，脚本会打印警告
* submodule 不会下载；符号链接下载为包含目标路径的普通文件
* `--revision HEAD` 或分支名在续传期间若有新提交，已下载与未下载的文件可能来自不同 commit；需要一致性时请指定 commit
* 使用 aria2c 并传入 token 时，若下载中断，token 会随 aria2c 会话保存在 `.ghd/aria2c_urls.txt` 中（与 `hfd.sh` 行为一致）

---

## 3. Wrapper 脚本说明

本仓库提供了 **两种明确区分的使用模式**，用于不同场景。

---

### 3.1 `hfd_wrapper.sh` —— 非阻塞（单模型）

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

### 3.2 `hfd_wrapper_blocking.sh` —— 阻塞（单模型）

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

### 3.3 `hfd_batch.sh` —— 串行批量下载控制器

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

## 4. `batch_list.txt` 写法说明

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

## 5. 故障排查与进程管理

由于 `hfd.sh` 内部使用 **aria2**，下载异常时需要手动检查进程状态。

---

### 5.1 查看下载进程

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

### 5.2 安全终止下载

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

### 5.3 常见错误场景

**现象：**

* 多个模型同时下载
* 磁盘 / 网络负载异常

**原因：**

* 在 batch 场景中误用了 `hfd_wrapper.sh`（非阻塞）

**解决方案：**

* 终止所有 `hfd.sh` / `aria2`
* batch 只使用 `hfd_wrapper_blocking.sh`

---

## 6. 使用方式总结

| 使用场景     | 推荐脚本                      |
| -------- | ------------------------- |
| 单模型，后台下载 | `hfd_wrapper.sh`          |
| 单模型，等待完成 | `hfd_wrapper_blocking.sh` |
| 多模型，串行批量 | `hfd_batch.sh`            |

---

## License

MIT
