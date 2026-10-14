# OpenDDE 龙芯 SDAA 适配与验证报告

## 1. 结论摘要

- 官方示例：仓库 examples/example.json 共 3 个任务；7r6r 使用现成 MSA、BF16、10 步和 1 循环完成 CUDA/SDAA 对照（1/3）。完整 7wux、7pzb 未完成单卡对照；另一个带现成模板的官方 MGYP 输入在 SDAA 上显存不足。官方合成 protein_200 的 FP32/BF16 有界推理已完成。
- 精度：官方 7r6r 使用现成 MSA 的单次对照中，模型自评 pLDDT 为 CUDA 86.7382、SDAA 86.8255；相对 PDB 7R6R 实验结构的蛋白 A 链 Cα RMSD 分别为 4.197、4.038 Å（仅 167 个可匹配 Cα）。两份预测在全部 203 个蛋白 Cα 上互比的 RMSD 为 12.827 Å，比较范围不同。
- 性能：现成 MSA 的 7r6r 单次模型前向 CUDA 13.49 秒、SDAA 98.88 秒。两端均仅测一次，且 CUDA 测量时的设备负载尚未核实，耗时及其比值仅作原始记录，性能结论待同输入条件下复测。
- 适用范围与未解决问题：现成 MSA 的 7r6r 有界单卡推理已通；protein_200 及 7pzb 单链的搜索后推理也已测成功。7pzb 大归档的龙芯直连下载不稳定，模板扫描使用经 QEMU 运行的 x86_64 HMMER；345 残基 MGYP 和更长输入 OOM，多卡 Fold-CP 仍需 CUDA/NCCL。

## 2. 软件环境

| 环境 | 架构与系统 | 镜像 digest/ID | Python/框架及设备插件 | GPU/实际后端 | 环境锁 |
| --- | --- | --- | --- | --- | --- |
| CUDA 基线 | Intel Xeon Platinum 8468，x86_64，Linux 5.15 | 基础镜像 digest：sha256:2b59b1b91885677814f78be1f8df48a25d5dc952eb6580eaecfefca510f9afd3；实测容器 image ID 相同 | Python 3.11.16，PyTorch 2.7.1+cu126，CUDA 12.6 | NVIDIA H100 80 GB，cuda:0 | 复现工程外层 source.lock、locks/、checksums.sha256 |
| 龙芯适配 | Loongson-3C6000/D，loongarch64，Loongnix Server 23.1 | 本地基础镜像 ID：sha256:3e425da47a74a03b589f8e1c18a67dcb90c8bcbde977cc1df09fa01209b7a524；无 RepoDigest | Python 3.12.13，PyTorch 2.12.0，torch_sdaa 3.2.1 | 8 卡已映射；实测单进程 sdaa:0 | sdaa/source.sdaa.lock、sdaa/.env.sdaa.example |

权重、搜索数据库和输出均不随源码仓库提交。

## 3. 源码适配点

### 3.1 计算后端

| 文件或 patch | 原问题 | 最小改动 | 对官方算法的影响 |
| --- | --- | --- | --- |
| opendde/config/schema.py、opendde/utils/environment.py、runner/inference.py | 设备枚举和推理初始化仅识别 CUDA/MPS/CPU | 探测 torch_sdaa，选择 sdaa:0 并设置本地卡 | 模型公式不变；设备执行路径改变 |
| opendde/model/opendde.py、opendde/utils/seed.py、opendde/utils/torch_utils.py | TF32/cuDNN、同步、缓存和种子代码含 CUDA 专用调用 | 按设备分流，补 SDAA 播种、同步与缓存清理 | 原生跨后端随机数流仍不同 |
| runner/inference.py、opendde/utils/torch_utils.py | BF16 autocast 未覆盖 SDAA | 在 SDAA 路径启用 autocast；三角核选择 Torch 实现 | 低精度舍入与 CUDA 可能不同 |
| opendde/model/modules/transformer.py（AtomAttentionEncoder 两处） | 对 int64 的 ref_charge 直接调用 torch.arcsinh 时，SDAA 报 Found dtype Float but expected Long | 在普通窗口与 prepare_cache 路径先转为 self.linear_no_bias_ref_charge.weight.dtype，再执行 arcsinh 和原有线性投影 | arcsinh 公式及张量形状不变；显式类型转换可能产生浮点舍入差异 |
| opendde/model/sample_confidence.py（calculate_clash） | 布尔张量的 max(dim=-1)[0] 在 SDAA 报 argmax(): does not support bool input | 改用 any(dim=-1)，只判断是否存在 True，不再求最大值索引 | 对非空布尔输入，与原 max 取得的布尔值等价 |
| opendde/data/msa/msa_service_client.py | 公共 MSA HTTP 读取的固定超时太短 | 增加可选的读取超时，默认值保持原值 | 不改变现成 A3M 的直接推理 |

### 3.2 第三方依赖与 wheel

| 包及版本 | 为什么需要适配 | 来源/许可证 | 构建命令或 wheel 标签 | SHA-256 |
| --- | --- | --- | --- | ---  |
| Kalign 3.6.0（命令行程序，非 wheel） | 龙芯上需要原生 loongarch64 可执行文件 | 上游 TimoLassmann/kalign；许可证文本随构建产物保存 | sdaa/build-kalign-sdaa.sh；产物不提交仓库 | ecebb6b6320f1b242d982f4c8c5825c6c83585fedc49fa51c3086972ce0ea391 |

HMMER 是完整模板搜索的外部程序，当前使用 x86_64 程序加 QEMU；现成 MSA 的 7r6r 推理不依赖它，也不能把它写成已完成的龙芯原生 wheel。

## 4. 适配过程中遇到的问题

| 问题/报错与触发场景 | 原因 | 处理方法/修改位置 | 重跑结果与证据 | 回退或遗留风险 |
| --- | --- | --- | --- | --- |
| 启动推理时设备选择和 CUDA 专用调用不适用 | 上游只覆盖 CUDA/MPS/CPU | 第 3.1 节的设备、autocast 和 CUDA 条件分流 | doctor 选中 sdaa:0；7r6r BF16 完成 | Fold-CP 多进程仍需 CUDA/NCCL |
| protein_200 在 torch.arcsinh(ref_charge) 报 Found dtype Float but expected Long | int64 输入路径出现 Float/Long 类型不一致；仅凭日志不能定位是后端类型推导、调度还是内核问题 | transformer.py 两处将电荷转为投影层权重 dtype 后继续调用 arcsinh | core FP32/BF16 通过；arcsinh-int64-failure/ 留有原日志 | 浮点 arcsinh 可执行，不能概括为 SDAA 完全不支持该算子 |
| 置信度阶段 max(dim=-1)[0] 报 argmax(): does not support bool input | max(dim) 同时求值和索引；SDAA 在布尔索引计算路径报错 | sample_confidence.py 改用 any(dim=-1)，无需索引 | core 两种精度通过；bool-max-failure/ 留有原日志 | 对正常非空布尔输入结果等价；新输入仍需验证 |
| 相同 seed 的 CUDA/SDAA 坐标差异明显 | 两端原生高斯随机流不同；BF16 数值路径也有差异 | seed.py 加 SDAA 播种；另以共用 NumPy 噪声诊断 | 7r6r 原生 Cα RMSD 12.827 Å，共用噪声 3.921 Å | 共用噪声不是生产路径，仍有数值差异 |
| 693 token 输入及官方 MGYP 在单卡 OOM | Torch 报告约 14.94 GiB 可用；三角注意力或三角乘法申请大块显存 | 使用官方较短 7r6r 做可比验证；撤回无效的实验性分块 | 7r6r BF16 成功；MGYP softmax 申请 5.09 GiB 失败，见 sdaa_mgyp_bf16.run.log | 长输入未解决 |
| MSA 搜索初期被 SKIP；7pzb 大结果直连下载失败 | 旧验收误用不存在的 /version 接口；服务端完成后结果下载超时或不完整；HMMER 非龙芯原生 | 修正预探测和可选读取超时；7pzb 归档经中转后在龙芯解析，HMMER 经 QEMU 扫描 | protein_200 的 MSA→模板→推理成功；7pzb 真 MSA→模板→单链推理成功，见 work/sdaa/search_20261013/ | 7pzb 大归档直连、原生 HMMER 性能和完整复合物推理仍未解决 |

## 5. 精度对比

### 5.1 官方 7r6r：现成 MSA

主对比使用官方 `examples/example.json` 的 7r6r 单任务、仓库自带配对/非配对 MSA 和相同 `opendde.pt` 权重。两端均为 `opendde_v1`、seed 101、BF16、1 样本、10 扩散步、1 循环、Torch 三角核，关闭模板与 TF32，不重新搜索。实际读入 245 token、2529 原子、703 条 MSA。只有一个种子；没有预先设定等价阈值。

| 指标 | 比较方法 | CUDA | 龙芯 SDAA | SDAA - CUDA |
| --- | --- | ---: | ---: | ---: |
| pLDDT | 模型自评置信度 | 86.7382 | 86.8255 | +0.0873 |
| pTM | 模型自评置信度 | 0.8805 | 0.8928 | +0.0123 |
| ipTM | 模型自评置信度 | 0.9320 | 0.9281 | -0.0039 |
| 蛋白 Cα 对齐 RMSD | 两份预测的全部 203 个 Cα | — | — | 两端之间 12.827 Å |
| Cα 两两距离 MAE | 两份预测内部成对距离 | — | — | 两端之间 7.299 Å |

另以 [PDB 7R6R](https://www.rcsb.org/structure/7R6R) 的实验结构作为参考。该条目为 3.13 Å 的 X 射线结构；所用参考 CIF 的 SHA-256 为 cda5bae340e43103672082f9ae4a721c6d23398833d77dafb12fa5a784f5c242。按蛋白 A 链序列匹配，只使用实验结构中有坐标且两份预测均有对应残基的 167 个 Cα。各预测独立进行刚体对齐。
| 相对实验结构指标，seed 101 | CUDA | 龙芯 SDAA | SDAA - CUDA |
| --- | ---: | ---: | ---: |
| 蛋白 A 链 Cα RMSD，越低越好 | 4.197 Å | 4.038 Å | -0.159 Å |
| Cα 局部距离一致率，越高越好 | 0.4519 | 0.4857 | +0.0338 |

在相同 167 个 Cα 上，两份预测之间的对齐 RMSD 为 5.323 Å；前表的 12.827 Å 使用全部 203 个预测 Cα，比较范围不同。单个种子且两端原生随机数流不同，不能据此判定 SDAA 稳定优于 CUDA，也不能仅凭 pLDDT 评价真实结构精度。

## 6. 性能对比

### 6.1 官方 7r6r：现成 MSA

同第 5.1 节，单进程、实际单卡；`Model forward time` 与 `Job completed in` 来自 OpenDDE 日志。模型前向不包含全部特征构建和写出。该组每端仅运行一次，不能计算中位数或波动范围。

| 后端 | 次数 | 模型前向，秒 | 整次任务，秒 | 原始日志 |
| --- | ---: | ---: | ---: | --- |
| CUDA/H100 | 1 | 13.49 | 24.90 | `work/official_compare_20261013/cuda_7r6r_bf16.run.log` |
| 龙芯/SDAA sdaa:0 | 1 | 98.88 | 112.70 | `work/sdaa/prepared_direct_20261013/7r6r_bf16/run.log` |

按这一次原始记录计算，SDAA/CUDA 前向耗时比为 7.33，整次任务耗时比为 4.53。CUDA 测量时的设备负载尚未核实，且每端仅一次运行，这些比值不能作为稳定的设备性能结论；需在相同输入、空闲设备和重复运行条件下复测。合成 `protein_200` 的辅助单次前向：FP32 CUDA/SDAA 为 4.07/80.65 秒（19.8 倍），BF16 为 3.47/47.05 秒（13.6 倍）；这些比值也仅供参考。

## 7. 复现命令

下列命令用仓库已有的现成 MSA 直接推理 7r6r，不触发在线搜索。**容器工作目录必须是 `/workspace/repro/OpenDDE`**，因为官方 JSON 中的旧格式 MSA 路径为 `./examples/7r6r/msa/1`；输入 JSON 则使用绝对路径。先用 `nvidia-smi` 选空闲 CUDA 卡，再替换 `CUDA_GPU` 的值。运行结果应显示 `N_msa 703`，且日志不能出现 `MSA server search started`。输出目录名每次改新，以免覆盖历史证据。

CUDA 端：

~~~bash
set -euo pipefail
PROJECT_DIR="REPLACE_WITH_CUDA_REPRO_ROOT"
cd "$PROJECT_DIR"
nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader
CUDA_GPU=2  # 运行前改为实际空闲的宿主机 GPU 编号
RUN_NAME=7r6r_bf16_recheck_01
test ! -e "work/official_compare_20261013/$RUN_NAME"
docker exec -e CUDA_VISIBLE_DEVICES="$CUDA_GPU" opendde-repro /bin/bash -lc \
  "cd /workspace/repro/OpenDDE && \
   test -s examples/7r6r/msa/1/pairing.a3m && \
   test -s examples/7r6r/msa/1/non_pairing.a3m && \
   opendde pred -i /workspace/repro/work/official_compare_20261013/input_7r6r.json \
   -o /workspace/repro/work/official_compare_20261013/$RUN_NAME \
   -s 101 -n opendde_v1 --device cuda --use_msa true --use_template false \
   --use_rna_msa false --trimul_kernel torch --triatt_kernel torch \
   --enable_tf32 false --sample 1 --step 10 --cycle 1 --dtype bf16" \
  > "work/official_compare_20261013/$RUN_NAME.run.log" 2>&1
grep 'N_msa 703' "work/official_compare_20261013/$RUN_NAME.run.log"
if grep -q 'MSA server search started' "work/official_compare_20261013/$RUN_NAME.run.log"; then exit 1; fi
~~~

龙芯 SDAA 端：

~~~bash
set -euo pipefail
PROJECT_DIR="REPLACE_WITH_SDAA_REPRO_ROOT"
cd "$PROJECT_DIR"
RUN_NAME=7r6r_bf16_recheck_01
test ! -e "work/sdaa/prepared_direct_20261013/$RUN_NAME"
docker exec opendde-sdaa /bin/bash -lc \
  "cd /workspace/repro/OpenDDE && \
   test -s examples/7r6r/msa/1/pairing.a3m && \
   test -s examples/7r6r/msa/1/non_pairing.a3m && \
   opendde pred -i /workspace/repro/work/sdaa/prepared_direct_20261013/input_7r6r.json \
   -o /workspace/repro/work/sdaa/prepared_direct_20261013/$RUN_NAME \
   -s 101 -n opendde_v1 --device sdaa --use_msa true --use_template false \
   --use_rna_msa false --trimul_kernel torch --triatt_kernel torch \
   --enable_tf32 false --sample 1 --step 10 --cycle 1 --dtype bf16" \
  > "work/sdaa/prepared_direct_20261013/$RUN_NAME.run.log" 2>&1
grep 'N_msa 703' "work/sdaa/prepared_direct_20261013/$RUN_NAME.run.log"
if grep -q 'MSA server search started' "work/sdaa/prepared_direct_20261013/$RUN_NAME.run.log"; then exit 1; fi
~~~
