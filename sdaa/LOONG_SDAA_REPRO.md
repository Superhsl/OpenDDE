# OpenDDE 龙芯 SDAA 完整复现

本教程使用适配仓库和官方 `examples/example.json` 中的 7r6r 任务，调用仓库自带 MSA、通用权重 `opendde.pt`、BF16、seed 101、10 个扩散步、1 个循环，在 `sdaa:0` 生成结构。迁移问题与 CUDA 对比见 [SDAA_ADAPTATION.md](SDAA_ADAPTATION.md)。

## 1. 固定源码与环境

目标主机需为 loongarch64，有 Docker 权限、`/dev/tcaicard0` 至 `/dev/tcaicard7`、Git、Python 3、GCC 12.3.0 和 CMake 3.26.3。先加载锁定的本地基础镜像；其 tag 与 image ID 见 [source.sdaa.lock](build/source.sdaa.lock)。当前镜像没有可用的远端 RepoDigest，构建脚本会按本地内容寻址 image ID 校验。

从准备存放复现工程的目录执行，`REPO_URL` 为含 SDAA 修改的仓库，`ADAPT_COMMIT` 为要复现的完整提交 SHA：

```bash
test -n "$REPO_URL"
test -n "$ADAPT_COMMIT"
mkdir opendde-sdaa-repro
cd opendde-sdaa-repro
git clone "$REPO_URL" OpenDDE
git -C OpenDDE checkout --detach "$ADAPT_COMMIT"
test "$(uname -m)" = loongarch64
git -C OpenDDE rev-parse HEAD
BASE_IMAGE=$(sed -n 's/^base_image=//p' OpenDDE/sdaa/build/source.sdaa.lock)
EXPECTED_IMAGE_ID=$(sed -n 's/^base_image_id=//p' OpenDDE/sdaa/build/source.sdaa.lock)
test "$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}')" = "$EXPECTED_IMAGE_ID"
for card in 0 1 2 3 4 5 6 7; do test -e "/dev/tcaicard$card"; done
```

锁文件的 `source_commit` 是上游基线，不是适配提交。镜像 ID、设备或编译器版本不符时，先准备对应环境。

## 2. 准备权重和通用数据

外层目录与源码同级放置 `data/`、`work/`、`tmp/`、`vendor/`。这些目录不会提交仓库。官方 7r6r 示例需要 `data/checkpoint/opendde.pt`、`data/common/` 和仓库自带的 `OpenDDE/examples/7r6r/msa/`；无需 `data/search_database/`。可从同一发布版复制资产，或在外层目录运行：

```bash
mkdir -p data work tmp vendor
OPENDDE_ROOT_DIR="$PWD/data" bash OpenDDE/scripts/download_opendde_data.sh --skip-search-database
printf '%s  %s\n' \
  7b826620390afad877ee2babc6a4d0df81b94d3a0be030959853d6a7da0807cc \
  data/checkpoint/opendde.pt | sha256sum -c -
for f in components.cif components.cif.rdkit_mol.pkl release_date_cache.json obsolete_to_successor.json; do
  test -s "data/common/$f"
done
test -s OpenDDE/examples/7r6r/msa/1/pairing.a3m
test -s OpenDDE/examples/7r6r/msa/1/non_pairing.a3m
```

## 3. 构建并运行

```bash
OpenDDE/sdaa/build.sh
OpenDDE/sdaa/run.sh
```

首次调用 `build.sh` 时会从 [环境模板](build/.env.sdaa.example) 创建外层 `.env.sdaa`，自动填写宿主机 UID/GID，核对固定镜像和 [Kalign 锁](build/source.sdaa.lock)，必要时从源码构建龙芯原生 Kalign，再构建镜像和独立 venv，启动 `opendde-sdaa` 容器。同名容器存在时停止。源码与 `data/` 只读挂载，`work/` 与 `tmp/` 可写挂载。已有外层 `.dockerignore` 缺少必要规则时，脚本会先备份再补齐。若使用自定义配置，可设置 `OPENDDE_ENV_FILE` 指向已有文件。

`run.sh` 默认仅提取官方 7r6r 任务，每次新建 `work/sdaa/acceptance_*/official_7r6r_*/` 并保存输入、`run.log`、预测 CIF。日志应有 `N_msa 703`，不应出现 `MSA server search started`。10 步和 1 个循环用于有界复现，不等于上游完整默认推理量。可用 `OPENDDE_INFERENCE_STEPS` 和 `OPENDDE_INFERENCE_CYCLES` 调整。

## 4. 其他验收入口

```bash
OpenDDE/sdaa/run.sh doctor
OpenDDE/sdaa/run.sh core
OpenDDE/sdaa/run.sh search
```

`doctor` 检查设备、算子、BF16 与随机数；`core` 是轻量官方推理验收；`search` 需另备搜索服务、数据库和兼容的外部程序。完整 MSA 搜索不是上述 7r6r 推理的前提。更细的限制与已有实验数据见 [迁移记录](SDAA_ADAPTATION.md)。底层实现保存在 `scripts/`，Dockerfile 和版本锁保存在 `build/`。
