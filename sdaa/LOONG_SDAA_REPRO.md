# OpenDDE 龙芯 SDAA 复现教程

本教程适用于**包含 SDAA 源码修改和本目录文件的适配仓库提交**。目标是从干净检出运行官方 7r6r 示例：使用仓库自带 MSA、通用权重 opendde.pt、BF16、seed 101、10 个扩散步和 1 个循环，在单进程的 sdaa:0 上生成结构。完整适配问题与 CUDA 对比见 [SDAA_ADAPTATION.md](SDAA_ADAPTATION.md)。

## 1. 准备仓库与目标主机

需要 loongarch64 主机、Docker 权限、/dev/tcaicard0 至 /dev/tcaicard7、Git、Python 3、GCC 12.3.0 和 CMake 3.26.3。构建脚本会映射 8 张卡，推理示例只使用 sdaa:0。基础镜像须事先在本机提供；当前锁定的本地镜像 tag 为 lasermpnn-sdaa321-loong:torch2.12.0-sdaa3.2.1-py312，image ID 见 [source.sdaa.lock](source.sdaa.lock)。该镜像没有可用的远端 RepoDigest，不能仅凭 tag 判断镜像相同。

发布仓库后，先在 shell 中设置 REPO_URL 为**含 SDAA 修改的仓库地址**，ADAPT_COMMIT 为该仓库的**完整适配提交 SHA**。锁文件中的 source_commit 是上游基线提交，不能替代 ADAPT_COMMIT。从准备存放复现工程的目录执行：

~~~bash
set -euo pipefail
test -n "$REPO_URL"
test -n "$ADAPT_COMMIT"
mkdir opendde-sdaa-repro
cd opendde-sdaa-repro
git clone "$REPO_URL" OpenDDE
git -C OpenDDE checkout --detach "$ADAPT_COMMIT"
test "$(uname -m)" = loongarch64
git -C OpenDDE rev-parse HEAD
git -C OpenDDE status --short

BASE_IMAGE=$(sed -n 's/^base_image=//p' OpenDDE/sdaa/source.sdaa.lock)
EXPECTED_IMAGE_ID=$(sed -n 's/^base_image_id=//p' OpenDDE/sdaa/source.sdaa.lock)
test "$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}')" = "$EXPECTED_IMAGE_ID"
for card in 0 1 2 3 4 5 6 7; do test -e "/dev/tcaicard$card"; done
/opt/tecoai/bin/teco-smi
~~~

如果镜像 ID、设备或编译器版本不符，先准备与锁文件一致的环境；不要只改锁值来跳过校验。

## 2. 准备运行数据与构建配置

外层复现工程采用如下布局；data/、work/、tmp/ 和 vendor/ 不属于源码仓库，也不应提交：

~~~text
opendde-sdaa-repro/
├── OpenDDE/             # 含 sdaa/ 的适配仓库
├── data/
│   ├── checkpoint/opendde.pt
│   └── common/
├── vendor/kalign-3.6.0/
├── work/
├── tmp/
├── .dockerignore
└── .env.sdaa
~~~

在外层目录继续执行。环境示例中的 UID/GID 要改为当前宿主机用户；基础镜像 ID 保持与锁文件一致。

~~~bash
mkdir -p data work tmp vendor
cp OpenDDE/sdaa/dockerignore .dockerignore
cp OpenDDE/sdaa/.env.sdaa.example .env.sdaa
sed -i "s/^HOST_UID=.*/HOST_UID=$(id -u)/" .env.sdaa
sed -i "s/^HOST_GID=.*/HOST_GID=$(id -g)/" .env.sdaa
~~~

官方数据脚本从发布源获取通用权重和 common/ 文件。该示例使用**现成 MSA**，不需要大型 search_database/。如果服务器不能访问下载源，可从已准备好的同一发布版复制这些资产到相同目录，跳过下面的下载命令，再执行其余校验。

~~~bash
OPENDDE_ROOT_DIR="$PWD/data" bash OpenDDE/scripts/download_opendde_data.sh --skip-search-database
printf '%s  %s\n' \
  7b826620390afad877ee2babc6a4d0df81b94d3a0be030959853d6a7da0807cc \
  data/checkpoint/opendde.pt | sha256sum -c -
for f in components.cif components.cif.rdkit_mol.pkl release_date_cache.json obsolete_to_successor.json; do
  test -s "data/common/$f"
done
test -s OpenDDE/examples/7r6r/msa/1/pairing.a3m
test -s OpenDDE/examples/7r6r/msa/1/non_pairing.a3m
~~~

权重 SHA-256 来自仓库的 opendde/config/model_manifest.json。此最小示例不需要 opendde_abag.pt、搜索数据库或在线 MSA 服务。

## 3. 构建 Kalign、镜像和独立容器

Kalign 是构建脚本要求的龙芯原生程序；[build-kalign-sdaa.sh](build-kalign-sdaa.sh) 按锁定源码和编译器构建，并校验二进制 SHA-256。[build-sdaa.sh](build-sdaa.sh) 再核对基础镜像、UID/GID 和 Kalign，构建镜像 opendde-sdaa:torch2.12-sdaa3.2.1，并启动名为 opendde-sdaa 的容器。容器使用独立 venv /opt/venvs/opendde-sdaa，OpenDDE/ 与 data/ 只读挂载，work/ 与 tmp/ 可写挂载。

~~~bash
OpenDDE/sdaa/build-kalign-sdaa.sh
OpenDDE/sdaa/build-sdaa.sh
OpenDDE/sdaa/run-official-examples-sdaa.sh doctor
~~~

doctor 的日志保存在 work/sdaa/acceptance/logs/doctor-run.log；应看到 selected_device=sdaa:0、必要算子和 BF16 检查通过。若同名容器已存在，构建脚本会停止；先核对已有容器，勿覆盖其输出。

## 4. 运行官方 7r6r 现成 MSA 示例

官方 examples/example.json 有三个任务；下面只提取 7r6r。**必须在容器内的 /workspace/repro/OpenDDE 目录运行**，因为示例 JSON 的现成 MSA 路径是相对路径 ./examples/7r6r/msa/1。输入 JSON 使用容器内绝对路径，防止误触发在线搜索。每次换一个新的 RUN_DIR，避免覆盖历史结果。

~~~bash
export RUN_DIR=work/sdaa/tutorial_7r6r_seed101
test ! -e "$RUN_DIR"
mkdir -p "$RUN_DIR"
python3 - <<'PY'
import json
import os
from pathlib import Path
jobs = json.loads(Path("OpenDDE/examples/example.json").read_text())
chosen = [job for job in jobs if job["name"] == "7r6r"]
assert len(chosen) == 1
(Path(os.environ["RUN_DIR"]) / "input_7r6r.json").write_text(
    json.dumps(chosen, indent=2) + "\n"
)
PY

docker exec -e RUN_DIR="$RUN_DIR" opendde-sdaa /bin/bash -lc '
  cd /workspace/repro/OpenDDE &&
  test -s examples/7r6r/msa/1/pairing.a3m &&
  test -s examples/7r6r/msa/1/non_pairing.a3m &&
  opendde pred \
    -i "/workspace/repro/$RUN_DIR/input_7r6r.json" \
    -o "/workspace/repro/$RUN_DIR/result" \
    -s 101 -n opendde_v1 --device sdaa \
    --use_msa true --use_template false --use_rna_msa false \
    --trimul_kernel torch --triatt_kernel torch --enable_tf32 false \
    --sample 1 --step 10 --cycle 1 --dtype bf16
' > "$RUN_DIR/run.log" 2>&1
~~~

这是已跑通的单卡、有界推理参数；10 步和 1 循环用于复现验证，不等于上游完整默认推理量。
